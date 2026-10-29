import { test } from 'node:test'
import assert from 'node:assert/strict'
import { extract, parseModelJson, completeStream, validateExtraction, whenHappened } from './llm.ts'

const GOOD = {
  keep: true,
  reason: 'work update',
  sensitivity: 'none',
  context: 'professional',
  summary: 'Launch tomorrow.',
  entities: [{ name: 'Priya', type: 'person' }],
  edges: [{ source: 'Priya', relation: 'owns', target: 'Launch' }],
  action_items: [{ text: 'Finish pricing', owner: 'Priya' }],
}

const anthropicReply = (text: string): Response =>
  new Response(JSON.stringify({ content: [{ type: 'text', text }], usage: { input_tokens: 1, output_tokens: 1 } }), { status: 200 })

test('parseModelJson strips code fences and surrounding prose', () => {
  assert.deepEqual(parseModelJson('```json\n{"a":1}\n```'), { a: 1 })
  assert.deepEqual(parseModelJson('Here you go: {"a":2} hope it helps'), { a: 2 })
  assert.throws(() => parseModelJson('no json here'))
})

test('extract calls claude-haiku-5-5 with the key and the transcript, and returns a validated extraction', async () => {
  let seen: { url: string; init: RequestInit } | undefined
  const fake = (async (url: string, init: RequestInit) => {
    seen = { url, init }
    return anthropicReply(JSON.stringify(GOOD))
  }) as unknown as typeof fetch

  const ex = await extract('Priya owns the launch pricing', { fetch: fake, apiKey: 'k' })

  assert.equal(seen?.url, 'https://api.anthropic.com/v1/messages')
  const headers = seen?.init.headers as Record<string, string>
  assert.equal(headers['x-api-key'], 'k')
  assert.equal(headers['anthropic-version'], '2023-06-01')
  const body = JSON.parse(String(seen?.init.body))
  assert.equal(body.model, 'claude-haiku-5-5')
  assert.ok(JSON.stringify(body.messages).includes('Priya owns the launch pricing'))
  assert.deepEqual(ex, { ...GOOD, keywords: [], happened: '' })
})

test('extract forces JSON with a schema, so short notes cannot get a prose reply', async () => {
  let body: { output_config?: { effort?: string; format?: { type: string; schema: { required: string[] } } }; thinking?: unknown } = {}
  const fake = (async (_url: string, init: RequestInit) => { body = JSON.parse(String(init.body)); return anthropicReply(JSON.stringify(GOOD)) }) as unknown as typeof fetch
  await extract('Gym at 7', { fetch: fake, apiKey: 'k' })
  assert.equal(body.output_config?.format?.type, 'json_schema')
  assert.deepEqual(body.output_config?.format?.schema.required.sort(), ['action_items', 'context', 'edges', 'entities', 'happened', 'keep', 'keywords', 'reason', 'sensitivity', 'summary'])
  assert.equal(body.output_config?.effort, 'medium', 'speed settings are kept alongside the format')
})

test('extract puts the user glossary in the system prompt, and omits the section when empty', async () => {
  const systems: string[] = []
  const fake = (async (_url: string, init: RequestInit) => {
    systems.push(JSON.parse(String(init.body)).system)
    return anthropicReply(JSON.stringify(GOOD))
  }) as unknown as typeof fetch

  await extract('t', { fetch: fake, apiKey: 'k' }, ['Zentro', 'Nimbus'])
  await extract('t', { fetch: fake, apiKey: 'k' })

  assert.match(systems[0], /Zentro/)
  assert.match(systems[0], /Nimbus/)
  assert.match(systems[0], /exact spelling/i)
  assert.doesNotMatch(systems[1], /Known vocabulary/)
})

test('extract adds facts about the user to the system prompt when given', async () => {
  const systems: string[] = []
  const fake = (async (_url: string, init: RequestInit) => {
    systems.push(JSON.parse(String(init.body)).system)
    return anthropicReply(JSON.stringify(GOOD))
  }) as unknown as typeof fetch
  await extract('t', { fetch: fake, apiKey: 'k' }, [], ['Riya is the engineering manager', 'Leo and Mia are the founders'])
  await extract('t', { fetch: fake, apiKey: 'k' })
  assert.match(systems[0], /About the user/)
  assert.match(systems[0], /Riya is the engineering manager/)
  assert.match(systems[0], /Leo and Mia are the founders/)
  assert.doesNotMatch(systems[1], /About the user/)
})

test('context is one of company, professional, personal; anything else fails closed to personal', async () => {
  const reply = (context: unknown) => (async () => anthropicReply(JSON.stringify({ ...GOOD, context }))) as unknown as typeof fetch
  assert.equal((await extract('t', { fetch: reply('company'), apiKey: 'k' })).context, 'company')
  assert.equal((await extract('t', { fetch: reply('professional'), apiKey: 'k' })).context, 'professional')
  assert.equal((await extract('t', { fetch: reply('personal'), apiKey: 'k' })).context, 'personal')
  assert.equal((await extract('t', { fetch: reply('work stuff'), apiKey: 'k' })).context, 'personal')
  assert.equal((await extract('t', { fetch: reply(undefined), apiKey: 'k' })).context, 'personal')
})

test('the system prompt defines the three spaces and the fail-closed rule', async () => {
  let system = ''
  const fake = (async (_u: string, init: RequestInit) => { system = JSON.parse(String(init.body)).system; return anthropicReply(JSON.stringify(GOOD)) }) as unknown as typeof fetch
  await extract('t', { fetch: fake, apiKey: 'k' })
  assert.match(system, /"company"/)
  assert.match(system, /employer/i)
  assert.match(system, /"professional"/)
  assert.match(system, /"personal"/)
  assert.match(system, /when unsure.*personal/is)
})

test('extract retries once when the first reply is not valid JSON', async () => {
  const replies = ['sorry, here is some prose', JSON.stringify(GOOD)]
  let calls = 0
  const fake = (async () => anthropicReply(replies[calls++])) as unknown as typeof fetch
  const ex = await extract('t', { fetch: fake, apiKey: 'k' })
  assert.equal(calls, 2)
  assert.equal(ex.keep, true)
})

test('extract rejects a reply with the wrong shape, and gives up after two bad replies', async () => {
  let calls = 0
  const fake = (async () => { calls++; return anthropicReply(JSON.stringify({ keep: 'yes' })) }) as unknown as typeof fetch
  await assert.rejects(extract('t', { fetch: fake, apiKey: 'k' }), /invalid extraction/)
  assert.equal(calls, 2)
})

test('extract surfaces API errors without retrying forever', async () => {
  let calls = 0
  const fake = (async () => { calls++; return new Response('{"error":{"message":"bad key"}}', { status: 401 }) }) as unknown as typeof fetch
  await assert.rejects(extract('t', { fetch: fake, apiKey: 'k' }), /401/)
  assert.equal(calls, 1)
})

function sse(parts: string[], chunkSizes?: number[]): Response {
  const body = parts.map((p) => `event: content_block_delta\ndata: ${JSON.stringify({ type: 'content_block_delta', index: 0, delta: { type: 'text_delta', text: p } })}\n\n`).join('')
    + 'event: message_stop\ndata: {"type":"message_stop"}\n\n'
  const bytes = new TextEncoder().encode(body)
  const sizes = chunkSizes ?? [bytes.length]
  let offset = 0
  const stream = new ReadableStream<Uint8Array>({
    pull(controller) {
      if (offset >= bytes.length) return controller.close()
      const size = sizes[Math.min(Math.floor(offset / 7), sizes.length - 1)] ?? 7
      controller.enqueue(bytes.slice(offset, offset + size))
      offset += size
    },
  })
  return new Response(stream, { status: 200, headers: { 'content-type': 'text/event-stream' } })
}

test('completeStream sends stream:true, calls back with each text piece in order, and returns the full text', async () => {
  let body: any
  const fake = (async (_u: string, init: RequestInit) => { body = JSON.parse(String(init.body)); return sse(['Hel', 'lo ', 'world.']) }) as unknown as typeof fetch
  const pieces: string[] = []
  const full = await completeStream('claude-haiku-5-5', 'sys', 'hi', { fetch: fake, apiKey: 'k' }, (t) => pieces.push(t))
  assert.equal(body.stream, true)
  assert.deepEqual(pieces, ['Hel', 'lo ', 'world.'])
  assert.equal(full, 'Hello world.')
})

test('completeStream copes with events split across network chunks', async () => {
  const fake = (async () => sse(['अभिवादन ', 'दुनिया'], [5, 3, 11, 7])) as unknown as typeof fetch
  const pieces: string[] = []
  const full = await completeStream('m', 's', 'u', { fetch: fake, apiKey: 'k' }, (t) => pieces.push(t))
  assert.equal(full, 'अभिवादन दुनिया')
  assert.deepEqual(pieces, ['अभिवादन ', 'दुनिया'])
})

test('completeStream throws on a non-OK status without echoing the body', async () => {
  const fake = (async () => new Response('secret detail', { status: 529 })) as unknown as typeof fetch
  await assert.rejects(completeStream('m', 's', 'u', { fetch: fake, apiKey: 'k' }, () => {}), (e: Error) => /529/.test(e.message) && !/secret/.test(e.message))
})

test('sensitivity is normalised, and a missing or non-string value becomes unknown (blocked)', () => {
  const base = { keep: true, reason: '', context: 'company', summary: 's', entities: [], edges: [], action_items: [] }
  assert.equal(validateExtraction({ ...base, sensitivity: ' Financial ' }).sensitivity, 'financial')
  assert.equal(validateExtraction({ ...base }).sensitivity, 'unknown')
  assert.equal(validateExtraction({ ...base, sensitivity: 5 }).sensitivity, 'unknown')
})

test('quick replies skip silent thinking where the model allows it: off on Haiku, between_tools on Sonnet, lowest-cost effort on Opus', async () => {
  const bodies: any[] = []
  const f = (async (_u: string, init: RequestInit) => { bodies.push(JSON.parse(String(init.body))); return new Response(JSON.stringify({ content: [{ type: 'text', text: 'ok' }] }), { status: 200 }) }) as unknown as typeof fetch
  const { complete } = await import('./llm.ts')
  for (const m of ['claude-haiku-5-5', 'claude-sonnet-5-5', 'claude-opus-5-5']) await complete(m, 's', 'u', { fetch: f, apiKey: 'k' })
  assert.deepEqual(bodies[0].thinking, { type: 'disabled' })
  assert.deepEqual(bodies[1].thinking, { type: 'between_tools' })
  assert.equal(bodies[2].thinking, undefined) // cannot be disabled on Opus 5.5
  assert.equal(bodies[2].output_config.effort, 'medium')
})

test('search words come back cleaned: strings only, at most 15, and missing means none', () => {
  const words = Array.from({ length: 20 }, (_, i) => `w${i}`)
  assert.deepEqual(validateExtraction({ ...GOOD, keywords: ['trip', 7, ' yatra ', ''] }).keywords, ['trip', 'yatra'])
  assert.equal(validateExtraction({ ...GOOD, keywords: words }).keywords?.length, 15)
  assert.deepEqual(validateExtraction(GOOD).keywords, [])
})

test('when it happened comes back as a year, month or day, and anything else means unknown', () => {
  assert.equal(validateExtraction({ ...GOOD, happened: '2024-06' }).happened, '2024-06')
  assert.equal(validateExtraction({ ...GOOD, happened: '2024-06-15' }).happened, '2024-06-15')
  assert.equal(validateExtraction({ ...GOOD, happened: '2024' }).happened, '2024')
  assert.equal(validateExtraction({ ...GOOD, happened: 'last summer' }).happened, '')
  assert.equal(validateExtraction({ ...GOOD, happened: '2024-13-40' }).happened, '')
  assert.equal(validateExtraction(GOOD).happened, '')
})

test('working out when an existing note happened: imports only trust dates in the text', async () => {
  const seen: { system: string; user: string }[] = []
  const fake = (async (_u: string, init: RequestInit) => {
    const b = JSON.parse(String(init.body)); seen.push({ system: b.system, user: b.messages[0].content })
    return anthropicReply(JSON.stringify({ happened: '2024-03' }))
  }) as unknown as typeof fetch
  assert.equal(await whenHappened('Joined Acme in March 2024.', '2026-10-21 10:00:00', true, { fetch: fake, apiKey: 'k' }), '2024-03')
  assert.match(seen[0].user, /imported from a document/)
  assert.doesNotMatch(seen[0].user, /Said on/)
  await whenHappened('Ship it tomorrow.', '2026-10-21 10:00:00', false, { fetch: fake, apiKey: 'k' })
  assert.match(seen[1].user, /Said on:/)
})
