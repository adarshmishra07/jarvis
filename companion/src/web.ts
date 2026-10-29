// Web search and page reading for the companion zone. TinyFish first (free tier), Firecrawl as fallback.
// Only a search query or a list of URLs ever leaves the machine here, never note text.

export type Provider = 'tinyfish' | 'firecrawl'

export interface LedgerEntry {
  ts: string
  provider: Provider
  kind: 'search' | 'fetch'
  payload: string // the query or the URLs: exactly what left the machine
  status: number
}

export interface WebDeps {
  fetch: typeof fetch
  tinyfishKey?: string
  firecrawlKey?: string
  ledger?: (entry: LedgerEntry) => void
  /** Wait between retries when a provider says slow down (429). Tests set 0. */
  retryDelayMs?: number
}

export interface SearchResult {
  title: string
  url: string
  snippet: string
  source: Provider
  /** Full page markdown, when the provider returned it with the search. Saves a separate read. */
  text?: string
}

export interface Page {
  url: string
  title: string
  text: string
  source: Provider
}

const TINYFISH_SEARCH = 'https://api.search.tinyfish.ai'
const TINYFISH_FETCH = 'https://api.fetch.tinyfish.ai'
const FIRECRAWL_SEARCH = 'https://api.firecrawl.dev/v2/search'
const FIRECRAWL_SCRAPE = 'https://api.firecrawl.dev/v2/scrape'
const MAX_QUERY_CHARS = 500 // Firecrawl's limit; TinyFish allows more but one rule is simpler
const TINYFISH_CONCURRENCY = 5 // one request per URL: measured faster than one batch (3.5 s vs 5 s for 5 pages)

function record(deps: WebDeps, provider: Provider, kind: LedgerEntry['kind'], payload: string, status: number): void {
  deps.ledger?.({ ts: new Date().toISOString(), provider, kind, payload, status })
}

function checkQuery(query: string): string {
  const q = query.trim()
  if (!q || q.length > MAX_QUERY_CHARS) throw new Error(`query must be 1 to ${MAX_QUERY_CHARS} characters`)
  return q
}

function checkUrls(urls: string[]): string[] {
  for (const u of urls) {
    let parsed: URL
    try { parsed = new URL(u) } catch { throw new Error('invalid URL') }
    if (parsed.protocol !== 'http:' && parsed.protocol !== 'https:') throw new Error('only http(s) URLs can be read')
  }
  return urls
}

async function tinyfishSearch(query: string, deps: WebDeps): Promise<SearchResult[]> {
  const response = await deps.fetch(`${TINYFISH_SEARCH}?query=${encodeURIComponent(query)}`, {
    headers: { 'X-API-Key': deps.tinyfishKey as string },
  })
  record(deps, 'tinyfish', 'search', query, response.status)
  if (!response.ok) throw new Error(`tinyfish search failed: ${response.status}`)
  const data = (await response.json()) as { results?: { title?: string; url?: string; snippet?: string }[] }
  return (data.results ?? []).filter((r) => r.url).map((r) => ({ title: r.title ?? '', url: r.url as string, snippet: r.snippet ?? '', source: 'tinyfish' as const }))
}

async function firecrawlSearch(query: string, limit: number, deps: WebDeps): Promise<SearchResult[]> {
  const response = await deps.fetch(FIRECRAWL_SEARCH, {
    method: 'POST',
    headers: { authorization: `Bearer ${deps.firecrawlKey}`, 'content-type': 'application/json' },
    body: JSON.stringify({ query, limit, scrapeOptions: { formats: ['markdown'], onlyMainContent: true } }),
  })
  record(deps, 'firecrawl', 'search', query, response.status)
  if (!response.ok) throw new Error(`firecrawl search failed: ${response.status}`)
  const data = (await response.json()) as { data?: { web?: { title?: string; url?: string; description?: string; markdown?: string | null }[] } }
  return (data.data?.web ?? []).filter((r) => r.url).map((r) => ({
    title: r.title ?? '', url: r.url as string, snippet: r.description ?? '', source: 'firecrawl' as const, text: r.markdown || undefined,
  }))
}

export async function webSearch(query: string, deps: WebDeps, limit = 5): Promise<SearchResult[]> {
  const q = checkQuery(query)
  if (!deps.tinyfishKey && !deps.firecrawlKey) throw new Error('no search provider configured')
  if (deps.tinyfishKey) {
    try {
      const hits = await tinyfishSearch(q, deps)
      if (hits.length > 0 || !deps.firecrawlKey) return hits.slice(0, limit)
    } catch (error) {
      if (!deps.firecrawlKey) throw error
    }
  }
  return firecrawlSearch(q, limit, deps)
}

const SCRAPE_ATTEMPTS = 3
const SCRAPE_CONCURRENCY = 2 // Firecrawl rate-limits bursts, so never fire many scrapes at once

async function firecrawlScrape(url: string, deps: WebDeps): Promise<Page | null> {
  for (let attempt = 1; attempt <= SCRAPE_ATTEMPTS; attempt++) {
    const response = await deps.fetch(FIRECRAWL_SCRAPE, {
      method: 'POST',
      headers: { authorization: `Bearer ${deps.firecrawlKey}`, 'content-type': 'application/json' },
      body: JSON.stringify({ url }),
    })
    record(deps, 'firecrawl', 'fetch', url, response.status)
    if (response.status === 429 && attempt < SCRAPE_ATTEMPTS) {
      await new Promise((resolve) => setTimeout(resolve, (deps.retryDelayMs ?? 1500) * attempt))
      continue
    }
    if (!response.ok) return null
    const data = (await response.json()) as { data?: { markdown?: string; metadata?: { title?: string } } }
    const text = data.data?.markdown ?? ''
    return text ? { url, title: data.data?.metadata?.title ?? '', text, source: 'firecrawl' } : null
  }
  return null
}

async function scrapeAll(urls: string[], deps: WebDeps): Promise<Page[]> {
  const queue = [...urls]
  const pages: Page[] = []
  const worker = async (): Promise<void> => {
    for (let url = queue.shift(); url !== undefined; url = queue.shift()) {
      const page = await firecrawlScrape(url, deps)
      if (page) pages.push(page)
    }
  }
  await Promise.all(Array.from({ length: SCRAPE_CONCURRENCY }, worker))
  return pages
}

async function tinyfishReadOne(url: string, deps: WebDeps): Promise<Page | null> {
  const response = await deps.fetch(TINYFISH_FETCH, {
    method: 'POST',
    headers: { 'X-API-Key': deps.tinyfishKey as string, 'content-type': 'application/json' },
    body: JSON.stringify({ urls: [url], format: 'markdown' }),
  })
  record(deps, 'tinyfish', 'fetch', url, response.status)
  if (!response.ok) return null
  const data = (await response.json()) as { results?: { url: string; title?: string; text?: string }[] }
  const hit = (data.results ?? []).find((r) => typeof r.text === 'string' && r.text.trim())
  return hit ? { url, title: hit.title ?? '', text: hit.text as string, source: 'tinyfish' } : null
}

async function tinyfishRead(urls: string[], deps: WebDeps): Promise<{ pages: Page[]; failed: string[] }> {
  const results: (Page | null)[] = new Array(urls.length).fill(null)
  let next = 0
  const worker = async (): Promise<void> => {
    for (let i = next++; i < urls.length; i = next++) {
      try { results[i] = await tinyfishReadOne(urls[i], deps) } catch { results[i] = null }
    }
  }
  await Promise.all(Array.from({ length: Math.min(TINYFISH_CONCURRENCY, urls.length) }, worker))
  return {
    pages: results.filter((p): p is Page => p !== null),
    failed: urls.filter((_, i) => results[i] === null),
  }
}

export async function webRead(urls: string[], deps: WebDeps): Promise<Page[]> {
  checkUrls(urls)
  const first = deps.tinyfishKey ? await tinyfishRead(urls, deps) : { pages: [] as Page[], failed: urls }
  if (!deps.firecrawlKey) return first.pages
  const rescued = await scrapeAll(first.failed, deps)
  const order = new Map(urls.map((u, i) => [u, i]))
  return [...first.pages, ...rescued].sort((a, b) => (order.get(a.url) ?? 0) - (order.get(b.url) ?? 0))
}
