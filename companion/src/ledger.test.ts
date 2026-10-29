import { test } from 'node:test'
import assert from 'node:assert/strict'
import { mkdtempSync, statSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { ledgered, readLedger } from './ledger.ts'

test('creates the ledger and its folder owner-only, and records host and path without the query or body', async () => {
  const path = join(mkdtempSync(join(tmpdir(), 'led-')), 'new', 'dir', 'ledger.jsonl')
  const f = ledgered((async () => new Response('{}', { status: 200 })) as unknown as typeof fetch, path)
  await f('https://example.com/search?q=secret+words', { method: 'POST', body: 'note text' })
  const rows = readLedger(path, 5)
  assert.deepEqual([rows[0].host, rows[0].path, rows[0].bytes, rows[0].status], ['example.com', '/search', 9, 200])
  assert.ok(!JSON.stringify(rows).includes('secret') && !JSON.stringify(rows).includes('note text'))
  assert.equal(statSync(path).mode & 0o777, 0o600)
})
