import { test } from 'node:test'
import assert from 'node:assert/strict'
import http from 'node:http'
import { lstatSync, mkdtempSync, symlinkSync } from 'node:fs'
import { join } from 'node:path'
import { tmpdir } from 'node:os'
import { Browser, clearStaleLock, isCritical, isPrivateAddress } from './browser.ts'

const PAGE = `<html><head><title>Atlas tracker</title></head><body>
<h1>Atlas tracker</h1><p>Launch owner: Asha</p>
<label>Search <input name="q" placeholder="Search"></label><button onclick="document.querySelector('#out').textContent='searched '+document.querySelector('input').value">Go</button>
<p id="out"></p><button>Place order</button></body></html>`

test('the browser opens a page, reads it, types, clicks, and takes a screenshot', async (t) => {
  const server = http.createServer((_, res) => { res.setHeader('content-type', 'text/html'); res.end(PAGE) }).listen(0)
  const port = (server.address() as { port: number }).port
  const browser = new Browser(mkdtempSync(join(tmpdir(), 'pk-browser-')), { allowPrivate: true }) // the test page is local
  t.after(async () => { await browser.close(); server.close() })
  const opened = await browser.open(`http://127.0.0.1:${port}/`)
  assert.equal(opened.title, 'Atlas tracker')
  assert.match(opened.text, /Launch owner: Asha/)
  await browser.type('Search', 'orbit')
  const after = await browser.click('Go')
  assert.match(after.text, /searched orbit/)
  assert.ok((await browser.screenshot()).length > 1000, 'a JPEG came back')
  assert.deepEqual(await browser.check('Place order'), { name: 'Place order', sendsForm: false })
})

test('a page opened while the browser window takes a frame starts one browser, not two', async (t) => {
  const server = http.createServer((_, res) => { res.setHeader('content-type', 'text/html'); res.end(PAGE) }).listen(0)
  const port = (server.address() as { port: number }).port
  const browser = new Browser(mkdtempSync(join(tmpdir(), 'pk-browser-')), { allowPrivate: true })
  t.after(async () => { await browser.close(); server.close() })
  // The app's browser window asks for a screenshot and the page text at the same moment the task opens a page.
  const [opened, shot, read] = await Promise.all([browser.open(`http://127.0.0.1:${port}/`), browser.screenshot(), browser.read()])
  assert.equal(opened.title, 'Atlas tracker')
  assert.ok(shot.length > 0 && typeof read.url === 'string')
})

test('the user can click by position, type and press keys in the page', async (t) => {
  const page = `<html><body style="margin:0"><input id="f" style="position:absolute;left:0;top:0;width:1280px;height:430px" onkeydown="if(event.key==='Enter')document.title='sent '+this.value"></body></html>`
  const server = http.createServer((_, res) => { res.setHeader('content-type', 'text/html'); res.end(page) }).listen(0)
  const port = (server.address() as { port: number }).port
  const browser = new Browser(mkdtempSync(join(tmpdir(), 'pk-browser-')), { allowPrivate: true })
  t.after(async () => { await browser.close(); server.close() })
  await browser.open(`http://127.0.0.1:${port}/`)
  await browser.userClick(0.5, 0.25)  // inside the input, which covers the top half
  await browser.userType('hello')
  await browser.userKey('Enter')
  assert.equal((await browser.read()).title, 'sent hello')
})

test('by default the browser cannot reach this Mac or the local network, even through a page', async (t) => {
  const server = http.createServer((_, res) => res.end('secret router page')).listen(0)
  const port = (server.address() as { port: number }).port
  const browser = new Browser(mkdtempSync(join(tmpdir(), 'pk-browser-')))
  t.after(async () => { await browser.close(); server.close() })
  await assert.rejects(browser.open(`http://127.0.0.1:${port}/`))
  await assert.rejects(browser.open(`http://localhost:${port}/`))
})

test('private and local addresses are recognised', async () => {
  for (const h of ['127.0.0.1', 'localhost', '10.0.0.5', '192.168.1.1', '172.20.0.1', '169.254.169.254', '::1', 'printer.local', '::ffff:7f00:1', '::ffff:127.0.0.1', '::127.0.0.1', '64:ff9b::7f00:1', '2002:7f00:1::', 'fd00::1', 'fe80::1']) assert.equal(await isPrivateAddress(h), true, h)
  for (const h of ['93.184.216.34', '8.8.8.8', '::ffff:8.8.8.8', '2606:4700::1111']) assert.equal(await isPrivateAddress(h), false, h)
})

test('critical actions are recognised by what they do', () => {
  for (const t of ['Place order', 'Pay now', 'Buy', 'Send', 'Delete account', 'Transfer', 'Confirm payment', 'Publish', 'Submit application', 'Change password'])
    assert.equal(isCritical(t), true, t)
  for (const t of ['Go', 'Search', 'Next page', 'Show more', 'Open', 'Sign in']) assert.equal(isCritical(t), false, t)
})

test('a profile lock left by a browser that is gone is cleared, a live one is kept', () => {
  const dir = mkdtempSync(join(tmpdir(), 'pk-lock-'))
  const lock = join(dir, 'SingletonLock')
  const locked = (): boolean => { try { lstatSync(lock); return true } catch { return false } }
  symlinkSync('host.local-999999', lock)
  clearStaleLock(dir)
  assert.equal(locked(), false)
  symlinkSync(`host.local-${process.pid}`, lock)
  clearStaleLock(dir)
  assert.equal(locked(), true)
})

test('the browser tells sites it is a normal Chrome, so sites that refuse headless browsers still open', async (t) => {
  const server = http.createServer((req, res) => {
    // Like x.com: a headless browser gets a 403.
    if (/HeadlessChrome/.test(req.headers['user-agent'] ?? '')) { res.statusCode = 403; return res.end() }
    res.setHeader('content-type', 'text/html'); res.end('<title>Welcome</title><p>hello</p>')
  }).listen(0)
  const port = (server.address() as { port: number }).port
  const browser = new Browser(mkdtempSync(join(tmpdir(), 'pk-browser-')), { allowPrivate: true })
  t.after(async () => { await browser.close(); server.close() })
  assert.equal((await browser.open(`http://127.0.0.1:${port}/`)).title, 'Welcome')
})
