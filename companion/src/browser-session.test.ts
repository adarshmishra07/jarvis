import { test } from 'node:test'
import assert from 'node:assert/strict'
import { BrowserSession, type SessionBrowser } from './browser-session.ts'

function fakeBrowser() {
  const did: string[] = []
  const b: SessionBrowser = {
    screenshot: async () => Buffer.from('jpg'),
    read: async () => ({ url: 'https://linear.app/login', title: 'Log in', text: '' }),
    userClick: async (x, y) => { did.push(`click ${x.toFixed(2)},${y.toFixed(2)}`) },
    userType: async (t) => { did.push(`type ${t}`) },
    userKey: async (k) => { did.push(`key ${k}`) },
    userScroll: async (dy) => { did.push(`scroll ${dy}`) },
  }
  return { b, did }
}

test('watchers see the state change and frames while Jarvis works; the user cannot touch the page then', async () => {
  const { b, did } = fakeBrowser()
  const s = new BrowserSession(b, { frameMs: 20 })
  const seen: { state: string; frame?: string }[] = []
  const stop = s.watch((e) => seen.push(e))
  s.working()
  await new Promise((r) => setTimeout(r, 70))
  assert.ok(seen.some((e) => e.state === 'working' && e.frame), 'frames arrive while working')
  await assert.rejects(s.input({ kind: 'click', x: 0.5, y: 0.5 }), /Jarvis is in control/)
  assert.deepEqual(did, [])
  s.idle()
  assert.equal(seen.at(-1)!.state, 'idle')
  stop()
})

test('a handover gives the user control until they press continue, then Jarvis gets their note back', async () => {
  const { b, did } = fakeBrowser()
  const s = new BrowserSession(b, { frameMs: 20 })
  const seen: { state: string; reason?: string }[] = []
  s.watch((e) => seen.push(e))
  s.working()
  const waiting = s.askUser('Please log in to Linear')
  assert.equal(seen.at(-1)!.state, 'needsUser')
  assert.equal(seen.at(-1)!.reason, 'Please log in to Linear')
  await s.input({ kind: 'click', x: 0.25, y: 0.5 })
  await s.input({ kind: 'type', text: 'me@example.com' })
  await s.input({ kind: 'key', key: 'Enter' })
  await s.input({ kind: 'scroll', dy: 300 })
  await assert.rejects(s.input({ kind: 'key', key: 'Meta+Q' }), /not allowed/)
  s.resume('done, logged in')
  assert.match(await waiting, /done, logged in/)
  assert.equal(seen.at(-1)!.state, 'working', 'Jarvis takes over again')
  assert.deepEqual(did, ['click 0.25,0.50', 'type me@example.com', 'key Enter', 'scroll 300'])
  s.idle()
})

test('nobody answering a handover times out, and the session can be stopped', async () => {
  const { b } = fakeBrowser()
  const s = new BrowserSession(b, { frameMs: 20, handoverMs: 50 })
  assert.match(await s.askUser('Need a code'), /did not respond/)
  s.idle()
})
