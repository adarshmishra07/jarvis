import { test } from 'node:test'
import assert from 'node:assert/strict'
import { ImageGate, imageUrlsIn } from './images.ts'

const png = Buffer.from([0x89, 0x50, 0x4e, 0x47, 1, 2, 3])
function fakeFetch(seen: string[]) {
  return (async (url: string, init: RequestInit = {}) => {
    seen.push(`${url} ${init.redirect}`)
    if (url.includes('big')) return new Response(Buffer.alloc(6 * 1024 * 1024), { headers: { 'content-type': 'image/png' } })
    if (url.includes('page')) return new Response('<html>', { headers: { 'content-type': 'text/html' } })
    return new Response(png, { headers: { 'content-type': 'image/png' } })
  }) as unknown as typeof fetch
}
const isPrivate = async (h: string) => h === '127.0.0.1' || h.endsWith('.internal')

test('finds image links in tool results and pages', () => {
  assert.deepEqual(imageUrlsIn('see https://cdn.zentro.example/gen/abc.png and https://x.example/a.jpg?w=2, not https://x.example/doc'),
    ['https://cdn.zentro.example/gen/abc.png', 'https://x.example/a.jpg?w=2'])
})

test('images from sources load on their own; others need a click; unsafe ones never load', async () => {
  const seen: string[] = []
  const gate = new ImageGate(fakeFetch(seen), isPrivate)
  gate.trust('https://cdn.zentro.example/gen/abc.png')
  const ok = await gate.load('https://cdn.zentro.example/gen/abc.png', false)
  assert.equal(ok.status, 'ok')
  assert.equal(ok.mime, 'image/png')
  assert.ok(seen[0].endsWith(' error'), 'redirects are never followed')
  assert.equal((await gate.load('https://elsewhere.example/x.png', false)).status, 'ask', 'an unknown link waits for a click')
  assert.equal(seen.length, 1, 'nothing was fetched for it')
  assert.equal((await gate.load('https://elsewhere.example/x.png', true)).status, 'ok', 'a click loads it')
  assert.equal((await gate.load('http://elsewhere.example/x.png', true)).status, 'blocked', 'https only')
  assert.equal((await gate.load('https://127.0.0.1/x.png', true)).status, 'blocked', 'never local')
  assert.equal((await gate.load('https://a.example/big.png', true)).status, 'blocked', 'size cap')
  assert.equal((await gate.load('https://a.example/page.png', true)).status, 'blocked', 'must really be an image')
})

test('a huge image is cut off while downloading, not after', async () => {
  let pulled = 0
  const fetch = (async () => new Response(new ReadableStream({
    pull(c) { pulled++; c.enqueue(new Uint8Array(1024 * 1024)); if (pulled > 50) c.close() },
  }), { headers: { 'content-type': 'image/png' } })) as unknown as typeof fetch
  const gate = new ImageGate(fetch, async () => false)
  assert.equal((await gate.load('https://a.example/huge.png', true)).status, 'blocked')
  assert.ok(pulled <= 8, `stopped early (read ${pulled} MB)`)
})

test('only links on the connector\'s own site are trusted on their own', () => {
  const gate = new ImageGate((async () => new Response('')) as unknown as typeof fetch, async () => false)
  gate.trustFrom('https://mcp.zentro.example/mcp', 'made it: https://cdn.zentro.example/gen/a.png and an email pixel https://tracker.example/p.png')
  assert.deepEqual(gate.trustedList(), ['https://cdn.zentro.example/gen/a.png'])
})
