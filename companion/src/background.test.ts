import { test } from 'node:test'
import assert from 'node:assert/strict'
import { backgroundWorker, taskTools, webTool } from './background.ts'
import { TaskRunner } from './tasks.ts'

const sse = (events: object[]) => new Response(events.map((e) => `data: ${JSON.stringify(e)}\n\n`).join(''), { status: 200 })

test('the helper searches the web, counts its steps, and returns its report', async () => {
  const seen: { system: string; tools: string[] }[] = []
  let searched = ''
  const fetch = (async (url: string, init: RequestInit = {}) => {
    if (url.startsWith('https://api.search.tinyfish.ai')) {
      searched = new URL(url).searchParams.get('query') ?? ''
      return new Response(JSON.stringify({ results: [{ title: 'CRM prices', url: 'https://crm.example/prices', snippet: 'Basic plan 12 USD' }] }))
    }
    const body = JSON.parse(String(init.body))
    seen.push({ system: body.system, tools: body.tools.map((t: { name: string }) => t.name) })
    if (seen.length === 1) return sse([{ type: 'content_block_start', index: 0, content_block: { type: 'tool_use', id: 't1', name: 'web_search', input: {} } },
      { type: 'content_block_delta', index: 0, delta: { type: 'input_json_delta', partial_json: '{"query":"CRM pricing"}' } }, { type: 'content_block_stop', index: 0 },
      { type: 'message_delta', delta: { stop_reason: 'tool_use' } }])
    return sse([{ type: 'content_block_delta', index: 0, delta: { type: 'text_delta', text: 'The basic plan costs 12 USD.' } }, { type: 'message_delta', delta: { stop_reason: 'end_turn' } }])
  }) as unknown as typeof globalThis.fetch
  const work = backgroundWorker({ llm: { fetch, apiKey: 'k' }, web: { fetch, tinyfishKey: 'tf' }, connectors: async () => undefined, paused: () => false })
  let steps = 0
  const report = await work('Compare CRM prices', { signal: new AbortController().signal, step: () => steps++, approve: async () => false })
  assert.equal(report, 'The basic plan costs 12 USD.')
  assert.equal(searched, 'CRM pricing')
  assert.equal(steps, 1)
  assert.deepEqual(seen[0].tools, ['web_search'])
  assert.match(seen[0].system, /cannot answer questions/)
})

test('paused cloud processing stops a background task before it calls anything', async () => {
  const work = backgroundWorker({ llm: { fetch: (() => { throw new Error('called') }) as never, apiKey: 'k' }, connectors: async () => undefined, paused: () => true })
  await assert.rejects(work('x', { signal: new AbortController().signal, step: () => {}, approve: async () => false }), /paused/)
})

test('Jarvis starts a background task with a goal and can list them', async () => {
  const runner = new TaskRunner(() => new Promise(() => {}))
  const kit = taskTools(runner)
  assert.match(await kit.run('start_background_task', { goal: 'Summarise unread mail from this week' }), /Started background task \w+/)
  assert.deepEqual(JSON.parse(await kit.run('background_tasks', {})).map((t: { status: string }) => t.status), ['running'])
  await assert.rejects(kit.run('start_background_task', { goal: ' ' }), /goal/)
})

test('pausing cloud processing mid-task stops the next call to the outside', async () => {
  let paused = false
  let calls = 0
  const fetch = (async () => {
    calls++
    paused = true // the user pauses while the first step runs
    return sse([{ type: 'content_block_start', index: 0, content_block: { type: 'tool_use', id: 't1', name: 'web_search', input: {} } },
      { type: 'content_block_delta', index: 0, delta: { type: 'input_json_delta', partial_json: '{"query":"x"}' } }, { type: 'content_block_stop', index: 0 },
      { type: 'message_delta', delta: { stop_reason: 'tool_use' } }])
  }) as unknown as typeof globalThis.fetch
  const work = backgroundWorker({ llm: { fetch, apiKey: 'k' }, web: { fetch, tinyfishKey: 'tf' }, connectors: async () => undefined, paused: () => paused })
  await assert.rejects(work('x', { signal: new AbortController().signal, step: () => {}, approve: async () => false }), /paused/)
  assert.equal(calls, 1, 'nothing more went out after the pause')
})

test('a long web search from a background task needs the user\'s yes (it could carry data out)', async () => {
  const fetch = (async () => new Response(JSON.stringify({ results: [] }))) as unknown as typeof globalThis.fetch
  const asked: string[] = []
  const kit = webTool({ fetch, tinyfishKey: 'tf' }, async (what) => { asked.push(what); return false })
  assert.match(await kit.run('web_search', { query: 'x'.repeat(150) }), /declined/)
  await kit.run('web_search', { query: 'CRM pricing 2026' })
  assert.equal(asked.length, 1)
})

test('a background goal is scrubbed of login details before the helper (or the screen) sees it', async () => {
  const runner = new TaskRunner(() => new Promise(() => {}))
  const kit = taskTools(runner, (t) => t.replaceAll('Hunter2!x', '[sent by the user]'))
  await kit.run('start_background_task', { goal: 'Log in with Hunter2!x and export the report' })
  assert.equal(runner.list()[0].goal, 'Log in with [sent by the user] and export the report')
})
