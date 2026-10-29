import { test } from 'node:test'
import assert from 'node:assert/strict'
import { route } from './router.ts'

type Answers = { tier?: object; effort?: object; risky?: object; web?: object }

function reply(answers: Answers, status = 200): Response {
  return new Response(JSON.stringify({ model: 'jev-1.13.0', answers }), { status })
}

function tier(choice: string, confidence: number) {
  return { type: 'choice', choice, confidence, probabilities: { [choice]: confidence } }
}
const effort = (score: number) => ({ type: 'score', score, confidence: 0.8, probabilities: {} })
const risky = (noul: number) => ({ type: 'noul', noul })

function deps(fakeFetch: typeof fetch, timeoutMs = 800) {
  return { fetch: fakeFetch, apiKey: 'test-key', timeoutMs }
}

test('sends one request to systemone with bearer auth and only the question as state', async () => {
  let seen: { url: string; init: RequestInit } | undefined
  const fake = (async (url: string, init: RequestInit) => {
    seen = { url, init }
    return reply({ tier: tier('balanced', 0.9), effort: effort(1), risky: risky(0.1) })
  }) as unknown as typeof fetch

  const question = 'What did Priya say about the launch date?'
  await route(question, deps(fake))

  assert.equal(seen?.url, 'https://api.typesafe.ai/v1/systemone')
  assert.equal(seen?.init.method, 'POST')
  assert.equal((seen?.init.headers as Record<string, string>).authorization, 'Bearer test-key')
  const body = JSON.parse(String(seen?.init.body))
  assert.deepEqual(Object.keys(body).sort(), ['model', 'questions', 'state'])
  assert.equal(body.state, question) // nothing but the question: no note text can ride along
  assert.deepEqual(Object.keys(body.questions).sort(), ['effort', 'risky', 'tier', 'web'])
  assert.equal(body.questions.tier.type, 'choice')
  assert.deepEqual(Object.keys(body.questions.tier.criteria).sort(), ['balanced', 'deep', 'fast'])
  assert.equal(body.questions.effort.type, 'score')
  assert.equal(body.questions.effort.criteria.length, 4)
  assert.equal(body.questions.risky.type, 'noul')
})

test('risky above 0.7 forces opus and at least high effort', async () => {
  const fake = (async () => reply({ tier: tier('fast', 0.9), effort: effort(0), risky: risky(0.8) })) as unknown as typeof fetch
  const r = await route('Send the invoice reminder to everyone', deps(fake))
  assert.equal(r.model, 'claude-opus-5-5')
  assert.equal(r.effort, 'high')
})

test('downgrade to haiku needs confidence 0.6', async () => {
  const lowConf = (async () => reply({ tier: tier('fast', 0.5), effort: effort(0), risky: risky(0) })) as unknown as typeof fetch
  const highConf = (async () => reply({ tier: tier('fast', 0.7), effort: effort(0), risky: risky(0) })) as unknown as typeof fetch
  assert.equal((await route('q', deps(lowConf))).model, 'claude-sonnet-5-5')
  assert.equal((await route('q', deps(highConf))).model, 'claude-haiku-5-5')
})

test('upgrade to opus needs confidence 0.3', async () => {
  const lowConf = (async () => reply({ tier: tier('deep', 0.2), effort: effort(2), risky: risky(0) })) as unknown as typeof fetch
  const okConf = (async () => reply({ tier: tier('deep', 0.3), effort: effort(2), risky: risky(0) })) as unknown as typeof fetch
  assert.equal((await route('q', deps(lowConf))).model, 'claude-sonnet-5-5')
  assert.equal((await route('q', deps(okConf))).model, 'claude-opus-5-5')
})

test('effort score maps by rounding to low, medium, high, xhigh', async () => {
  const make = (s: number) => (async () => reply({ tier: tier('balanced', 0.9), effort: effort(s), risky: risky(0) })) as unknown as typeof fetch
  assert.equal((await route('q', deps(make(0.2)))).effort, 'low')
  assert.equal((await route('q', deps(make(1.4)))).effort, 'medium')
  assert.equal((await route('q', deps(make(2.4)))).effort, 'high')
  assert.equal((await route('q', deps(make(3)))).effort, 'xhigh')
})

test('fails open to sonnet on timeout, non-2xx, and malformed body', async () => {
  const hang = ((_u: string, init: RequestInit) =>
    new Promise((_res, rej) => init.signal?.addEventListener('abort', () => rej(new Error('aborted'))))) as unknown as typeof fetch
  const down = (async () => reply({}, 500)) as unknown as typeof fetch
  const junk = (async () => new Response('not json', { status: 200 })) as unknown as typeof fetch
  const badTier = (async () => reply({ tier: tier('gigantic', 0.9) })) as unknown as typeof fetch

  for (const f of [hang, down, junk, badTier]) {
    const r = await route('q', deps(f, 50))
    assert.equal(r.model, 'claude-sonnet-5-5')
    assert.match(r.reason, /fallback/)
  }
})

test('the same call says whether the web is needed; unsure or down means no web', async () => {
  const with_ = (web?: number) => (async () => reply({ tier: tier('balanced', 0.9), effort: effort(1), risky: risky(0.1), ...(web === undefined ? {} : { web: risky(web) }) })) as unknown as typeof fetch
  assert.equal((await route('Weather in London today?', deps(with_(0.9)))).web, true)
  assert.equal((await route('When is my trip?', deps(with_(0.2)))).web, false)
  assert.equal((await route('x', deps(with_()))).web, false)
  const down = (async () => new Response('', { status: 503 })) as unknown as typeof fetch
  assert.equal((await route('Weather in London today?', deps(down))).web, false)
})
