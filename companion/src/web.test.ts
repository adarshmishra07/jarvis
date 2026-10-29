import { test } from 'node:test'
import assert from 'node:assert/strict'
import { webSearch, webRead, type LedgerEntry } from './web.ts'

interface Call { url: string; init: RequestInit }

function router(handlers: Record<string, (call: Call) => Response>, calls: Call[] = []): typeof fetch {
  return (async (url: string, init: RequestInit = {}) => {
    const call = { url: String(url), init }
    calls.push(call)
    const key = Object.keys(handlers).find((k) => call.url.startsWith(k))
    if (!key) throw new Error(`unexpected request ${call.url}`)
    return handlers[key](call)
  }) as unknown as typeof fetch
}

const json = (body: unknown, status = 200) => new Response(JSON.stringify(body), { status })

const TF_SEARCH = 'https://api.search.tinyfish.ai'
const TF_FETCH = 'https://api.fetch.tinyfish.ai'
const FC_SEARCH = 'https://api.firecrawl.dev/v2/search'
const FC_SCRAPE = 'https://api.firecrawl.dev/v2/scrape'

const tfResults = { query: 'q', total_results: 2, page: 0, results: [
  { position: 1, site_name: 'A', title: 'Alpha', snippet: 'about alpha', url: 'https://a.example/x' },
  { position: 2, site_name: 'B', title: 'Beta', snippet: 'about beta', url: 'https://b.example/y' },
] }

test('search uses TinyFish with the X-API-Key header and the query in the URL', async () => {
  const calls: Call[] = []
  const fetch = router({ [TF_SEARCH]: () => json(tfResults) }, calls)
  const hits = await webSearch('web automation tools', { fetch, tinyfishKey: 'tf-key' })
  assert.equal(calls.length, 1)
  assert.equal(calls[0].init.method ?? 'GET', 'GET')
  assert.equal((calls[0].init.headers as Record<string, string>)['X-API-Key'], 'tf-key')
  assert.equal(new URL(calls[0].url).searchParams.get('query'), 'web automation tools')
  assert.deepEqual(hits.map((h) => [h.title, h.url, h.snippet, h.source]), [
    ['Alpha', 'https://a.example/x', 'about alpha', 'tinyfish'],
    ['Beta', 'https://b.example/y', 'about beta', 'tinyfish'],
  ])
})

test('search falls back to Firecrawl (Bearer auth) when TinyFish fails', async () => {
  const calls: Call[] = []
  const fetch = router({
    [TF_SEARCH]: () => json({}, 500),
    [FC_SEARCH]: () => json({ success: true, data: { web: [{ title: 'Gamma', description: 'about gamma', url: 'https://c.example/z' }] } }),
  }, calls)
  const hits = await webSearch('q', { fetch, tinyfishKey: 'tf', firecrawlKey: 'fc-key' }, 3)
  const fc = calls.find((c) => c.url.startsWith(FC_SEARCH))!
  assert.equal((fc.init.headers as Record<string, string>).authorization, 'Bearer fc-key')
  assert.deepEqual(JSON.parse(String(fc.init.body)), { query: 'q', limit: 3, scrapeOptions: { formats: ['markdown'], onlyMainContent: true } })
  assert.deepEqual(hits.map((h) => [h.title, h.source]), [['Gamma', 'firecrawl']])
})

test('search works with only a Firecrawl key, and errors when no provider is configured', async () => {
  const fetch = router({ [FC_SEARCH]: () => json({ success: true, data: { web: [] } }) })
  assert.deepEqual(await webSearch('q', { fetch, firecrawlKey: 'fc' }), [])
  await assert.rejects(webSearch('q', { fetch }), /no search provider/i)
})

test('rejects empty and oversized queries before any request', async () => {
  const calls: Call[] = []
  const fetch = router({ [TF_SEARCH]: () => json(tfResults) }, calls)
  await assert.rejects(webSearch('   ', { fetch, tinyfishKey: 'k' }), /query/i)
  await assert.rejects(webSearch('x'.repeat(501), { fetch, tinyfishKey: 'k' }), /query/i)
  assert.equal(calls.length, 0)
})

test('read sends one TinyFish request per URL, in parallel (at most 5 at once), and keeps the original order', async () => {
  let inFlight = 0
  let maxInFlight = 0
  const calls: Call[] = []
  const fetch = router({
    [TF_FETCH]: async (c) => {
      inFlight++; maxInFlight = Math.max(maxInFlight, inFlight)
      await new Promise((r) => setTimeout(r, 5))
      inFlight--
      const urls = JSON.parse(String(c.init.body)).urls as string[]
      return json({ results: urls.map((u) => ({ url: u, final_url: u, title: 't', text: `text of ${u}`, format: 'markdown' })), errors: [] })
    },
  }, calls)
  const urls = Array.from({ length: 12 }, (_, i) => `https://s.example/${i}`)
  const pages = await webRead(urls, { fetch, tinyfishKey: 'tf' })
  assert.equal(calls.length, 12)
  assert.ok(calls.every((c) => JSON.parse(String(c.init.body)).urls.length === 1))
  assert.equal(JSON.parse(String(calls[0].init.body)).format, 'markdown')
  assert.ok(maxInFlight > 1 && maxInFlight <= 5, `max in flight was ${maxInFlight}`)
  assert.deepEqual(pages.map((p) => p.url), urls)
  assert.equal(pages[0].text, 'text of https://s.example/0')
})

test('read retries failed or empty URLs through Firecrawl scrape', async () => {
  const calls: Call[] = []
  const fetch = router({
    [TF_FETCH]: (c) => {
      const u = (JSON.parse(String(c.init.body)).urls as string[])[0]
      if (u.includes('bad')) return json({ results: [], errors: [{ url: u, error: 'blocked' }] })
      return json({ results: [{ url: u, final_url: u, title: 't', text: u.includes('empty') ? '' : 'fine', format: 'markdown' }], errors: [] })
    },
    [FC_SCRAPE]: (c) => json({ success: true, data: { markdown: `scraped ${JSON.parse(String(c.init.body)).url}`, metadata: { title: 'S' } } }),
  }, calls)
  const pages = await webRead(['https://ok.example', 'https://empty.example', 'https://bad.example'], { fetch, tinyfishKey: 'tf', firecrawlKey: 'fc' })
  const byUrl = Object.fromEntries(pages.map((p) => [p.url, p]))
  assert.equal(byUrl['https://ok.example'].source, 'tinyfish')
  assert.equal(byUrl['https://empty.example'].text, 'scraped https://empty.example')
  assert.equal(byUrl['https://bad.example'].source, 'firecrawl')
})

test('rejects non-http(s) URLs', async () => {
  const fetch = router({ [TF_FETCH]: () => json({ results: [], errors: [] }) })
  await assert.rejects(webRead(['file:///etc/passwd'], { fetch, tinyfishKey: 'k' }), /http/i)
  await assert.rejects(webRead(['javascript:alert(1)'], { fetch, tinyfishKey: 'k' }), /http/i)
})

test('the egress ledger records exactly what left, and never an API key', async () => {
  const entries: LedgerEntry[] = []
  const fetch = router({ [TF_SEARCH]: () => json(tfResults), [TF_FETCH]: () => json({ results: [], errors: [] }) })
  const deps = { fetch, tinyfishKey: 'super-secret-key', ledger: (e: LedgerEntry) => entries.push(e) }
  await webSearch('private project name', deps)
  await webRead(['https://a.example/x'], deps)
  assert.deepEqual(entries.map((e) => [e.provider, e.kind, e.payload, e.status]), [
    ['tinyfish', 'search', 'private project name', 200],
    ['tinyfish', 'fetch', 'https://a.example/x', 200],
  ])
  assert.ok(!JSON.stringify(entries).includes('super-secret-key'))
})

test('Firecrawl search returns page markdown as text so no separate read is needed', async () => {
  const fetch = router({ [FC_SEARCH]: () => json({ success: true, data: { web: [
    { title: 'G', description: 'd', url: 'https://c.example/z', markdown: '# Full page' },
    { title: 'H', description: 'd2', url: 'https://d.example/w' },
  ] } }) })
  const hits = await webSearch('q', { fetch, firecrawlKey: 'fc' })
  assert.deepEqual(hits.map((h) => h.text), ['# Full page', undefined])
})

test('Firecrawl scrape retries when rate limited (429) and then succeeds', async () => {
  let attempts = 0
  const fetch = router({ [FC_SCRAPE]: () => (++attempts < 3 ? json({}, 429) : json({ success: true, data: { markdown: 'finally', metadata: { title: 'T' } } })) })
  const pages = await webRead(['https://slow.example'], { fetch, firecrawlKey: 'fc', retryDelayMs: 0 })
  assert.equal(attempts, 3)
  assert.equal(pages[0].text, 'finally')
})

test('Firecrawl scrape gives up after repeated 429s and does not flood: at most 2 scrapes run at once', async () => {
  let inFlight = 0
  let maxInFlight = 0
  const fetch = router({ [FC_SCRAPE]: async () => { inFlight++; maxInFlight = Math.max(maxInFlight, inFlight); await new Promise((r) => setTimeout(r, 5)); inFlight--; return json({}, 429) } })
  const pages = await webRead(['https://a.example', 'https://b.example', 'https://c.example', 'https://d.example'], { fetch, firecrawlKey: 'fc', retryDelayMs: 0 })
  assert.deepEqual(pages, [])
  assert.ok(maxInFlight <= 2, `max in flight was ${maxInFlight}`)
})
