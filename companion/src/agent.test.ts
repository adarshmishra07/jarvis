import { test } from 'node:test'
import assert from 'node:assert/strict'
import { streamAgent } from './agent.ts'

const sse = (events: object[]): Response =>
  new Response(events.map((e) => `event: x\ndata: ${JSON.stringify(e)}\n\n`).join(''), { status: 200 })

const toolTurn = (): Response => sse([
  { type: 'content_block_start', index: 0, content_block: { type: 'text', text: '' } },
  { type: 'content_block_delta', index: 0, delta: { type: 'text_delta', text: 'Let me look. ' } },
  { type: 'content_block_stop', index: 0 },
  { type: 'content_block_start', index: 1, content_block: { type: 'tool_use', id: 'tu_1', name: 'browser_open', input: {} } },
  { type: 'content_block_delta', index: 1, delta: { type: 'input_json_delta', partial_json: '{"url": "https://ex' } },
  { type: 'content_block_delta', index: 1, delta: { type: 'input_json_delta', partial_json: 'ample.com"}' } },
  { type: 'content_block_stop', index: 1 },
  { type: 'message_delta', delta: { stop_reason: 'tool_use' } },
])
const finalTurn = (): Response => sse([
  { type: 'content_block_start', index: 0, content_block: { type: 'text', text: '' } },
  { type: 'content_block_delta', index: 0, delta: { type: 'text_delta', text: 'It says hello.' } },
  { type: 'content_block_stop', index: 0 },
  { type: 'message_delta', delta: { stop_reason: 'end_turn' } },
])

test('runs the tools the model asks for, feeds results back, and streams all text', async () => {
  const bodies: any[] = []
  const replies = [toolTurn(), finalTurn()]
  const fetch = (async (_u: string, init: RequestInit) => { bodies.push(JSON.parse(String(init.body))); return replies.shift()! }) as unknown as typeof fetch
  const ran: [string, unknown][] = []
  let streamed = ''
  const text = await streamAgent({
    model: 'claude-sonnet-5-5', system: 'sys', messages: [{ role: 'user', content: 'what is on example.com?' }], maxTokens: 500,
    deps: { fetch, apiKey: 'k' }, onText: (t) => { streamed += t },
    tools: { definitions: [{ name: 'browser_open', description: 'd', input_schema: { type: 'object' } }], run: async (name, input) => { ran.push([name, input]); return 'Example Domain: hello' } },
  })
  assert.deepEqual(ran, [['browser_open', { url: 'https://example.com' }]])
  assert.equal(streamed, 'Let me look. It says hello.')
  assert.equal(text, 'Let me look. It says hello.')
  assert.equal(bodies[0].tools[0].name, 'browser_open')
  const second = bodies[1].messages
  assert.deepEqual(second.at(-2).content.map((b: { type: string }) => b.type), ['text', 'tool_use'])
  assert.deepEqual(second.at(-1).content, [{ type: 'tool_result', tool_use_id: 'tu_1', content: 'Example Domain: hello' }])
})

test('text from separate steps is separated by a space', async () => {
  const noSpace = (): Response => sse([{ type: 'content_block_start', index: 0, content_block: { type: 'text', text: '' } }, { type: 'content_block_delta', index: 0, delta: { type: 'text_delta', text: 'Checking.' } },
    { type: 'content_block_start', index: 1, content_block: { type: 'tool_use', id: 't', name: 'x', input: {} } }, { type: 'content_block_stop', index: 1 }, { type: 'message_delta', delta: { stop_reason: 'tool_use' } }])
  const replies = [noSpace(), finalTurn()]
  const fetch = (async () => replies.shift()!) as unknown as typeof fetch
  let streamed = ''
  const text = await streamAgent({ model: 'claude-sonnet-5-5', system: 's', messages: [{ role: 'user', content: 'q' }], maxTokens: 100, deps: { fetch, apiKey: 'k' }, onText: (t) => { streamed += t }, tools: { definitions: [], run: async () => 'ok' } })
  assert.equal(text, 'Checking. It says hello.')
  assert.equal(streamed, 'Checking. It says hello.')
})

test('a tool that fails tells the model instead of breaking the answer, and loops are capped', async () => {
  let calls = 0
  const fetch = (async () => { calls++; return toolTurn() }) as unknown as typeof fetch
  const text = await streamAgent({
    model: 'claude-sonnet-5-5', system: 's', messages: [{ role: 'user', content: 'q' }], maxTokens: 100, deps: { fetch, apiKey: 'k' }, onText: () => {},
    tools: { definitions: [], run: async () => { throw new Error('page did not load') } }, maxSteps: 3,
  })
  assert.equal(calls, 4, 'three steps, then one wrap-up turn')
  assert.match(text, /Let me look/)
})

test('the same action three times in a row is stopped, and failed tools are marked as errors', async () => {
  const bodies: any[] = []
  const fetch = (async (_u: string, init: RequestInit) => { bodies.push(JSON.parse(String(init.body))); return toolTurn() }) as unknown as typeof fetch
  let runs = 0
  await streamAgent({ model: 'claude-sonnet-5-5', system: 's', messages: [{ role: 'user', content: 'q' }], maxTokens: 100, deps: { fetch, apiKey: 'k' }, onText: () => {},
    tools: { definitions: [], run: async () => { runs++; throw new Error('page did not load') } }, maxSteps: 6 })
  assert.equal(runs, 2, 'the third identical call is not run')
  const third = bodies[3].messages.at(-1).content[0]
  assert.match(third.content, /same .* three times/i)
  assert.equal(bodies[1].messages.at(-1).content[0].is_error, true)
})

test('at the step limit Jarvis gets one last turn without tools to say where things stand', async () => {
  const bodies: any[] = []
  const fetch = (async (_u: string, init: RequestInit) => {
    const b = JSON.parse(String(init.body)); bodies.push(b)
    return b.tool_choice?.type === 'none' ? finalTurn() : toolTurn()
  }) as unknown as typeof fetch
  let n = 0
  const text = await streamAgent({ model: 'claude-sonnet-5-5', system: 's', messages: [{ role: 'user', content: 'q' }], maxTokens: 100, deps: { fetch, apiKey: 'k' }, onText: () => {},
    tools: { definitions: [{ name: 'browser_open', description: 'd', input_schema: { type: 'object' } }], run: async () => `page ${n++}` }, maxSteps: 2 })
  const last = bodies.at(-1)
  assert.deepEqual(last.tool_choice, { type: 'none' }, 'no tool use on the wrap-up turn')
  assert.match(JSON.stringify(last.messages.at(-1)), /step limit/i)
  assert.match(text, /It says hello/)
})

test('a cancelled run stops before its next tool: nothing more runs after the cancel', async () => {
  const stop = new AbortController()
  const two = sse([
    { type: 'content_block_start', index: 0, content_block: { type: 'tool_use', id: 'a', name: 'read_mail', input: {} } }, { type: 'content_block_stop', index: 0 },
    { type: 'content_block_start', index: 1, content_block: { type: 'tool_use', id: 'b', name: 'send_mail', input: {} } }, { type: 'content_block_stop', index: 1 },
    { type: 'message_delta', delta: { stop_reason: 'tool_use' } }])
  const ran: string[] = []
  const fetch = (async () => two) as unknown as typeof globalThis.fetch
  await assert.rejects(streamAgent({
    model: 'm', system: 's', messages: [{ role: 'user', content: 'x' }], maxTokens: 10, deps: { fetch, apiKey: 'k' }, onText: () => {}, signal: stop.signal,
    tools: { definitions: [], run: async (name) => { ran.push(name); if (name === 'read_mail') stop.abort(); return 'ok' } },
  }))
  assert.deepEqual(ran, ['read_mail'], 'send_mail never ran')
})
