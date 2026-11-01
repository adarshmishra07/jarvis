import { test } from 'node:test'
import assert from 'node:assert/strict'
import { tainted } from './taint.ts'
import { sensitive } from './never.ts'

test('what counts as sensitive: numbers, IDs, keys and codes, not plain email addresses', () => {
  for (const t of ['Your code is 482913 for login', '482913 is your verification code', '7731 is your Uber code', 'password: hunter22', 'key sk-test-abcdefghijklmnop1234', 'call +91 98765 43210', 'PAN ABCDE1234F'])
    assert.equal(sensitive(t), true, t)
  for (const t of ['From asha@example.com: lunch at 1pm?', 'Meeting 2026-10-31 14:00', 'Order 12345 shipped'])
    assert.equal(sensitive(t), false, t)
})

test('after a tool brings in a secret, every outbound step needs a yes; before it, none do', async () => {
  const asked: string[] = []
  let answer = false
  const ran: string[] = []
  const kit = tainted({ definitions: [], run: async (name) => { ran.push(name); return name === 'gmail_read' ? 'Your verification code is 993311' : 'ok' } },
    async (a) => { asked.push(a); return answer })
  await kit.run('browser_open', { url: 'https://a.example' })
  assert.equal(asked.length, 0, 'nothing sensitive yet')
  await kit.run('gmail_read', {})
  assert.match(String(await kit.run('browser_open', { url: 'https://b.example/?c=993311' })), /said no/)
  assert.match(String(await kit.run('type', { text: '993311' })), /said no/)
  await kit.run('recall', {}) // reading stays free
  answer = true
  await kit.run('browser_type', { field: 'Code', text: '993311' })
  assert.equal(asked.length, 3)
  assert.deepEqual(ran, ['browser_open', 'gmail_read', 'recall', 'browser_type'])
})

test('a screenshot or an earlier turn also counts, and an error that quotes a secret marks it too', async () => {
  const asked: string[] = []
  const shot = tainted({ definitions: [], run: async () => [{ type: 'image' as const, source: { type: 'base64' as const, media_type: 'image/jpeg', data: 'x' } }] }, async (a) => { asked.push(a); return false })
  await shot.run('screenshot', {})
  assert.match(String(await shot.run('browser_open', { url: 'https://a.example' })), /said no/)
  const earlier = tainted({ definitions: [], run: async () => 'ok' }, async (a) => { asked.push(a); return false }, true)
  assert.match(String(await earlier.run('browser_open', { url: 'https://a.example' })), /said no/)
  const err = tainted({ definitions: [], run: async (n) => { if (n === 'read') throw new Error('bad token sk-test-abcdefghijklmnopqrst'); return 'ok' } }, async (a) => { asked.push(a); return false })
  await assert.rejects(err.run('read', {}))
  assert.match(String(await err.run('browser_open', { url: 'https://a.example' })), /said no/)
  assert.equal(asked.length, 3)
})
