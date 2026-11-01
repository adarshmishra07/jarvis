import { test } from 'node:test'
import assert from 'node:assert/strict'
import { mkdtempSync, readFileSync } from 'node:fs'
import { join } from 'node:path'
import { tmpdir } from 'node:os'
import { metered, spend, usageOf, cost } from './usage.ts'

test('usage is read from streams and plain replies, and priced by model (unknown models at the highest price)', () => {
  const stream = 'event: m\ndata: {"type":"message_start","message":{"usage":{"input_tokens":1000,"cache_read_input_tokens":2000,"output_tokens":1}}}\n\ndata: {"type":"message_delta","usage":{"output_tokens":500}}\n'
  assert.deepEqual(usageOf(stream), { input_tokens: 1000, cache_read_input_tokens: 2000, output_tokens: 500 })
  assert.deepEqual(usageOf('{"usage":{"input_tokens":3,"output_tokens":4}}'), { input_tokens: 3, output_tokens: 4 })
  const row = { ts: '', model: 'claude-opus-5-5', input: 1_000_000, output: 1_000_000, cacheWrite: 0, cacheRead: 1_000_000 }
  assert.equal(cost(row), 4 + 20 + 0.2)
  assert.equal(cost({ ...row, model: 'claude-new-9' }), 10 + 50 + 0.25)
})

test('every Messages call is metered without touching the response, and spend adds up per day', async () => {
  const path = join(mkdtempSync(join(tmpdir(), 'usage-')), 'usage.jsonl')
  const base = (async () => new Response('{"usage":{"input_tokens":1000000,"output_tokens":0}}', { status: 200 })) as unknown as typeof fetch
  const f = metered(base, path)
  const r = await f('https://api.anthropic.com/v1/messages', { method: 'POST', body: JSON.stringify({ model: 'claude-sonnet-5-5', messages: [{ role: 'user', content: 'secret text' }] }) })
  assert.match(await r.text(), /input_tokens/, 'the caller still gets the whole body')
  await f('https://example.com/v1/messages', {})
  await new Promise((done) => setTimeout(done, 20))
  const saved = readFileSync(path, 'utf8')
  assert.equal(saved.trim().split('\n').length, 1, 'only Anthropic calls')
  assert.ok(!saved.includes('secret'), 'no prompt text is stored')
  const s = spend(path)
  assert.equal(s.today, 2)
  assert.equal(s.days[0].calls, 1)
})
