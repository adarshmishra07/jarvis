// What Jarvis spends on Claude: every Messages call's token counts (read from the response, never its text), priced and
// added up per day, so the app can show the cost and background work can stop at a daily budget. Stored next to the
// ledger as one line per call: time, model and four numbers. No prompt or answer text is ever written.
import { appendFileSync, existsSync, readFileSync, writeFileSync, chmodSync } from 'node:fs'

/** US dollars per million tokens: input, output, cache write, cache read (Anthropic list prices, Oct 2026). */
const PRICES: Record<string, [number, number, number, number]> = {
  'claude-fable-5-1': [10, 50, 12.5, 0.25],
  'claude-opus-5-5': [4, 20, 5, 0.2],
  'claude-sonnet-5-5': [2, 10, 2.5, 0.2],
  'claude-haiku-5-5': [0.1, 0.5, 0.125, 0.01],
}
/** An unknown model is priced like the most expensive one, so the budget errs on the safe side. */
const UNKNOWN = PRICES['claude-fable-5-1']

export interface UsageRow { ts: string; model: string; input: number; output: number; cacheWrite: number; cacheRead: number }

export function cost(r: UsageRow): number {
  const [i, o, w, c] = PRICES[r.model] ?? UNKNOWN
  return (r.input * i + r.output * o + r.cacheWrite * w + r.cacheRead * c) / 1e6
}

interface ApiUsage { input_tokens?: number; output_tokens?: number; cache_creation_input_tokens?: number; cache_read_input_tokens?: number }

/** The usage in a Messages response: plain JSON, or a stream (message_start has input, message_delta the final output). */
export function usageOf(body: string): ApiUsage | undefined {
  if (!body.trimStart().startsWith('{')) {
    let u: ApiUsage | undefined
    for (const line of body.split('\n')) {
      if (!line.startsWith('data:')) continue
      try {
        const e = JSON.parse(line.slice(5)) as { type?: string; message?: { usage?: ApiUsage }; usage?: ApiUsage }
        if (e.type === 'message_start' && e.message?.usage) u = { ...e.message.usage }
        if (e.type === 'message_delta' && e.usage) u = { ...u, ...Object.fromEntries(Object.entries(e.usage).filter(([, v]) => v != null)) }
      } catch { /* a line that is not JSON is skipped */ }
    }
    return u
  }
  try { return (JSON.parse(body) as { usage?: ApiUsage }).usage } catch { return undefined }
}

/** Wraps fetch so every Anthropic Messages call records its usage. The caller's response is untouched (a copy is read). */
export function metered(base: typeof fetch, usagePath: string): typeof fetch {
  if (!existsSync(usagePath)) { writeFileSync(usagePath, ''); chmodSync(usagePath, 0o600) }
  return (async (input: string | URL | Request, init?: RequestInit) => {
    const response = await base(input, init)
    const url = new URL(typeof input === 'string' || input instanceof URL ? input : input.url)
    if (url.host !== 'api.anthropic.com' || !url.pathname.startsWith('/v1/messages') || url.pathname.includes('count_tokens') || !response.ok) return response
    let model = ''
    try { model = String((JSON.parse(String(init?.body ?? '{}')) as { model?: unknown }).model ?? '') } catch { /* no model in the body */ }
    void response.clone().text().then((body) => {
      const u = usageOf(body)
      if (!u) return
      const row: UsageRow = { ts: new Date().toISOString(), model, input: u.input_tokens ?? 0, output: u.output_tokens ?? 0, cacheWrite: u.cache_creation_input_tokens ?? 0, cacheRead: u.cache_read_input_tokens ?? 0 }
      appendFileSync(usagePath, JSON.stringify(row) + '\n')
    }, () => undefined)
    return response
  }) as typeof fetch
}

export interface Spend { today: number; month: number; days: { day: string; usd: number; calls: number }[] }

/** Spend per local day for the last 30 days, today's, and this month's, in US dollars. */
export function spend(usagePath: string, now = new Date()): Spend {
  const rows = existsSync(usagePath) ? readFileSync(usagePath, 'utf8').split('\n').filter(Boolean).flatMap((l) => { try { return [JSON.parse(l) as UsageRow] } catch { return [] } }) : []
  const local = (d: Date): string => `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}-${String(d.getDate()).padStart(2, '0')}`
  const byDay = new Map<string, { usd: number; calls: number }>()
  for (const r of rows) {
    const day = local(new Date(r.ts))
    const d = byDay.get(day) ?? { usd: 0, calls: 0 }
    byDay.set(day, { usd: d.usd + cost(r), calls: d.calls + 1 })
  }
  const today = local(now), month = today.slice(0, 7)
  const since = local(new Date(now.getTime() - 30 * 86_400_000))
  const days = [...byDay].filter(([d]) => d > since).sort(([a], [b]) => b.localeCompare(a)).map(([day, v]) => ({ day, usd: v.usd, calls: v.calls }))
  return { today: byDay.get(today)?.usd ?? 0, month: [...byDay].filter(([d]) => d.startsWith(month)).reduce((s, [, v]) => s + v.usd, 0), days }
}
