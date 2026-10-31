import { test } from 'node:test'
import assert from 'node:assert/strict'
import { streamAgent, combineTools } from './agent.ts'
import { computerTools, COMPUTER_TOOLSET, type HandsCall } from './computer.ts'

const sse = (events: object[]): Response =>
  new Response(events.map((e) => `event: x\ndata: ${JSON.stringify(e)}\n\n`).join(''), { status: 200 })
/** One model turn that calls these tools (computer ones carry toolset_name). */
const calls = (...uses: { name: string; input?: object; computer?: boolean }[]): Response => sse([
  ...uses.flatMap((u, i) => [
    { type: 'content_block_start', index: i, content_block: { type: 'tool_use', id: `t${i}`, name: u.name, input: {}, ...(u.computer ? { toolset_name: 'computer' } : {}) } },
    { type: 'content_block_delta', index: i, delta: { type: 'input_json_delta', partial_json: JSON.stringify(u.input ?? {}) } },
    { type: 'content_block_stop', index: i }]),
  { type: 'message_delta', delta: { stop_reason: 'tool_use' } },
])
const done = (): Response => sse([{ type: 'content_block_start', index: 0, content_block: { type: 'text', text: '' } },
  { type: 'content_block_delta', index: 0, delta: { type: 'text_delta', text: 'Done.' } }, { type: 'message_delta', delta: { stop_reason: 'end_turn' } }])

const fakeHands = (log: string[], fail?: string): HandsCall => async (action, input) => {
  log.push(`${action} ${JSON.stringify(input ?? {})}`)
  if (action === fail) return { error: 'it broke' }
  return action === 'screenshot' ? { image: 'SHOT', width: 1232, height: 800, app: 'Notes' } : { text: 'OK' }
}

test('the computer tools appear only after the user agrees, and results echo the toolset', async () => {
  const log: string[] = []
  const asked: string[] = []
  const kit = computerTools(fakeHands(log), async (a) => { asked.push(a); return true })
  const bodies: any[] = []
  const replies = [calls({ name: 'use_computer', input: { task: 'write a note', app: 'Notes' } }),
    calls({ name: 'left_click', input: { coordinate: [10, 20] }, computer: true }, { name: 'type', input: { text: 'hi' }, computer: true }), done()]
  const fetch = (async (_u: string, init: RequestInit) => { bodies.push(JSON.parse(String(init.body))); return replies.shift()! }) as unknown as typeof fetch
  await streamAgent({ model: 'claude-sonnet-5-5', system: 's', messages: [{ role: 'user', content: 'write a note' }], maxTokens: 100, deps: { fetch, apiKey: 'k' }, onText: () => {}, tools: combineTools([kit]) })
  assert.deepEqual(bodies[0].tools.map((t: { name?: string }) => t.name), ['use_computer'])
  assert.deepEqual(bodies[1].tools, [kit.definitions[0], COMPUTER_TOOLSET])
  assert.match(asked[0], /Notes.*write a note/)
  assert.deepEqual(log, ['begin {"apps":"Notes"}', 'left_click {"coordinate":[10,20]}', 'type {"text":"hi"}', 'screenshot {}']) // a screenshot ends the batch
  const results = bodies[2].messages.at(-1).content
  assert.deepEqual(results.map((r: { toolset_name?: string }) => r.toolset_name), ['computer', 'computer'])
  assert.deepEqual(results[1].content.map((b: { type: string }) => b.type), ['text', 'text', 'image'])
})

test('after a failed action the rest of the batch is not run', async () => {
  const log: string[] = []
  const kit = computerTools(fakeHands(log, 'left_click'), async () => true)
  await kit.run('use_computer', { task: 't', app: 'a' })
  const bodies: any[] = []
  const replies = [calls({ name: 'left_click', computer: true }, { name: 'type', input: { text: 'x' }, computer: true }), done()]
  const fetch = (async (_u: string, init: RequestInit) => { bodies.push(JSON.parse(String(init.body))); return replies.shift()! }) as unknown as typeof fetch
  await streamAgent({ model: 'm', system: 's', messages: [{ role: 'user', content: 'x' }], maxTokens: 100, deps: { fetch, apiKey: 'k' }, onText: () => {}, tools: kit })
  const results = bodies[1].messages.at(-1).content
  assert.equal(results[0].is_error, true)
  assert.equal(results[1].content, 'Not executed: an earlier computer action in this turn failed.')
  assert.deepEqual(log, ['begin {"apps":"a"}', 'left_click {}']) // nothing typed, no screenshot
})

test('nothing runs on the screen when the user says no, and risky steps ask', async () => {
  const log: string[] = []
  const kit = computerTools(fakeHands(log), async () => false)
  await assert.rejects(kit.run('use_computer', { task: 't', app: 'a' }), /said no/)
  await assert.rejects(kit.run('left_click', {}), /use_computer first/)
  assert.deepEqual(log, [])
  assert.equal(kit.maxSteps, undefined)
  const yes = computerTools(fakeHands(log), async (a) => !a.includes('Send'))
  await yes.run('use_computer', { task: 't', app: 'a' })
  assert.equal(yes.maxSteps, 60)
  await assert.rejects(yes.run('confirm_on_screen', { action: 'Send the email' }), /declined/)
})
