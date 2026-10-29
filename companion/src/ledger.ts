import { appendFileSync, readFileSync, writeFileSync, existsSync, chmodSync, mkdirSync } from 'node:fs'
import { dirname } from 'node:path'

export interface LedgerRow { ts: string; method: string; host: string; path: string; bytes: number; status: number }

/** Wraps fetch so every outbound call is recorded: host, path (no query, no headers, no body), size, status. */
export function ledgered(base: typeof fetch, ledgerPath: string): typeof fetch {
  mkdirSync(dirname(ledgerPath), { recursive: true, mode: 0o700 })
  if (!existsSync(ledgerPath)) { writeFileSync(ledgerPath, ''); chmodSync(ledgerPath, 0o600) }
  return (async (input: string | URL | Request, init?: RequestInit) => {
    const url = new URL(typeof input === 'string' || input instanceof URL ? input : input.url)
    const bytes = typeof init?.body === 'string' ? Buffer.byteLength(init.body) : 0
    let status = 0
    try {
      const response = await base(input, init)
      status = response.status
      return response
    } finally {
      const row: LedgerRow = { ts: new Date().toISOString(), method: init?.method ?? 'GET', host: url.host, path: url.pathname, bytes, status }
      appendFileSync(ledgerPath, JSON.stringify(row) + '\n')
    }
  }) as typeof fetch
}

export function readLedger(ledgerPath: string, limit: number): LedgerRow[] {
  if (!existsSync(ledgerPath)) return []
  const lines = readFileSync(ledgerPath, 'utf8').split('\n').filter(Boolean)
  return lines.slice(-limit).map((l) => JSON.parse(l) as LedgerRow).reverse()
}

/** Records a page Jarvis's browser opened, in the same ledger as every other outbound call. */
export function recordVisit(ledgerPath: string, url: string): void {
  const u = new URL(url)
  const row: LedgerRow = { ts: new Date().toISOString(), method: 'BROWSE', host: u.host, path: u.pathname, bytes: 0, status: 0 }
  appendFileSync(ledgerPath, JSON.stringify(row) + '\n')
}
