import { execFileSync } from 'node:child_process'
import { existsSync, readdirSync, readlinkSync, rmSync } from 'node:fs'
import { lookup } from 'node:dns/promises'
import { BlockList, isIP } from 'node:net'
import { homedir } from 'node:os'
import { join } from 'node:path'
import { chromium, type BrowserContext, type Locator, type Page } from 'playwright-core'

// Jarvis's own browser: a separate Chromium profile (never the user's Chrome), headless, run by the companion.
// Logins made in it stay in its own profile folder. Page text is untrusted data, the same as web results.

const PAGE_TEXT_CHARS = 6000
const ACTION_TIMEOUT_MS = 8000
const NAV_TIMEOUT_MS = 20000
const HOST_CHECK_MS = 60_000
const VIEWPORT = { width: 1280, height: 860 }

/** Actions that spend money, send something on the user's behalf, or cannot be undone: these need the user's yes. */
const CRITICAL = /\b(buy|pay|purchase|order|checkout|send|post|publish|delete|remove|transfer|withdraw|submit|subscribe|unsubscribe|password|book now|reserve|confirm payment|sign up)\b/i
export const isCritical = (label: string): boolean => CRITICAL.test(label)

export interface PageView { url: string; title: string; text: string }

/** Loopback, private, link-local, carrier NAT and multicast. Two lists: Node checks IPv4 addresses against IPv6
 * rules too (as ::ffff:a.b.c.d), so one shared list would wrongly match every IPv4 address. */
const PRIVATE_V4 = new BlockList()
for (const [net, bits] of [['0.0.0.0', 8], ['10.0.0.0', 8], ['100.64.0.0', 10], ['127.0.0.0', 8], ['169.254.0.0', 16], ['172.16.0.0', 12], ['192.168.0.0', 16], ['224.0.0.0', 4]] as const)
  PRIVATE_V4.addSubnet(net, bits, 'ipv4')
const PRIVATE_V6 = new BlockList()
for (const [net, bits] of [['::', 128], ['::1', 128], ['fc00::', 7], ['fe80::', 10], ['ff00::', 8]] as const) PRIVATE_V6.addSubnet(net, bits, 'ipv6')

/** The IPv4 address an IPv6 address wraps or translates (mapped, compatible, NAT64, 6to4), if any. */
function embeddedV4(ip: string): string | null {
  const groups = expandV6(ip)
  if (!groups) return null
  const v4 = (hi: number, lo: number): string => [hi >> 8, hi & 255, lo >> 8, lo & 255].join('.')
  const zeros = (n: number): boolean => groups.slice(0, n).every((g) => g === 0)
  if (zeros(5) && (groups[5] === 0xffff || groups[5] === 0)) return v4(groups[6], groups[7]) // ::ffff:a.b.c.d and ::a.b.c.d
  if (groups[0] === 0x64 && groups[1] === 0xff9b && groups.slice(2, 6).every((g) => g === 0)) return v4(groups[6], groups[7]) // NAT64
  if (groups[0] === 0x2002) return v4(groups[1], groups[2]) // 6to4
  return null
}

/** Eight 16-bit groups, also for the dotted-quad tail form. */
function expandV6(ip: string): number[] | null {
  let s = ip.toLowerCase()
  const dotted = s.match(/(\d+\.\d+\.\d+\.\d+)$/)
  if (dotted) {
    const [a, b, c, d] = dotted[1].split('.').map(Number)
    s = s.slice(0, -dotted[1].length) + `${((a << 8) | b).toString(16)}:${((c << 8) | d).toString(16)}`
  }
  const [head, tail] = s.split('::')
  const h = head ? head.split(':') : []
  const t = tail !== undefined ? (tail ? tail.split(':') : []) : []
  const fill = tail !== undefined ? 8 - h.length - t.length : 0
  const all = [...h, ...Array(Math.max(0, fill)).fill('0'), ...t]
  return all.length === 8 ? all.map((g) => parseInt(g, 16) || 0) : null
}

const privateIp = (ip: string): boolean => {
  if (isIP(ip) === 4) return PRIVATE_V4.check(ip, 'ipv4')
  const inner = embeddedV4(ip)
  return inner ? PRIVATE_V4.check(inner, 'ipv4') : PRIVATE_V6.check(ip, 'ipv6')
}

/** This Mac or the local network (router, printers, other devices): the browser must never reach these. */
export async function isPrivateAddress(host: string): Promise<boolean> {
  const h = host.replace(/^\[|\]$/g, '').toLowerCase()
  if (h === 'localhost' || h.endsWith('.localhost') || h.endsWith('.local')) return true
  if (isIP(h)) return privateIp(h)
  try { return (await lookup(h, { all: true })).some((a) => privateIp(a.address)) } catch { return true } // unresolvable: refuse
}

/** What a click would really do: the element's own name, and whether it sends a form with data. */
export interface ClickCheck { name: string; sendsForm: boolean }

/** Chromium's profile lock left behind by a browser that is gone (the helper was killed or restarted): it would
 * refuse every later start with "profile in use". A lock whose process still runs is left alone. */
export function clearStaleLock(profileDir: string): void {
  let pid = 0
  try { pid = Number(readlinkSync(join(profileDir, 'SingletonLock')).split('-').pop()) } catch { return } // no lock
  try { if (pid > 0) { process.kill(pid, 0); return } } catch { /* that process is gone */ }
  for (const f of ['SingletonLock', 'SingletonCookie', 'SingletonSocket']) rmSync(join(profileDir, f), { force: true })
}

/**
 * The same Chrome's user agent without "Headless": some sites (x.com) refuse a headless browser outright with a 403.
 * The major version only, as Chrome itself reports it. Undefined if the version cannot be read: the default is used.
 */
export function plainUserAgent(executable: string): string | undefined {
  try {
    const major = execFileSync(executable, ['--version'], { encoding: 'utf8', timeout: 5000 }).match(/(\d+)\.\d+\.\d+/)?.[1]
    return major ? `Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/${major}.0.0.0 Safari/537.36` : undefined
  } catch {
    return undefined
  }
}

/** The newest Chromium that Playwright has already downloaded on this Mac. */
function cachedChromium(): string | undefined {
  const cache = join(homedir(), 'Library', 'Caches', 'ms-playwright')
  if (!existsSync(cache)) return undefined
  const builds = readdirSync(cache).filter((d) => /^chromium-\d+$/.test(d)).sort((a, b) => Number(b.split('-')[1]) - Number(a.split('-')[1]))
  for (const b of builds) {
    const exe = join(cache, b, 'chrome-mac-arm64', 'Google Chrome for Testing.app', 'Contents', 'MacOS', 'Google Chrome for Testing')
    if (existsSync(exe)) return exe
  }
  return undefined
}

export class Browser {
  private context?: BrowserContext
  private page?: Page

  private readonly profileDir: string
  private readonly allowPrivate: boolean
  private readonly hostCheck = new Map<string, { at: number; verdict: Promise<boolean> }>()

  /** Cached briefly only: a domain cannot stay approved and later switch to a local address for long.
   * ponytail: a DNS-rebinding window of HOST_CHECK_MS remains; pin resolved IPs through a local proxy to close it. */
  private blocked(host: string): Promise<boolean> {
    const hit = this.hostCheck.get(host)
    if (hit && Date.now() - hit.at < HOST_CHECK_MS) return hit.verdict
    const verdict = isPrivateAddress(host)
    this.hostCheck.set(host, { at: Date.now(), verdict })
    return verdict
  }
  constructor(profileDir: string, opts: { allowPrivate?: boolean } = {}) { this.profileDir = profileDir; this.allowPrivate = opts.allowPrivate === true }

  // One start shared by every caller: a second launch on the same profile fails ("ProcessSingleton"), and the app's
  // browser window asks for a frame at the same moment a task opens a page.
  private starting?: Promise<BrowserContext>

  private async current(): Promise<Page> {
    this.starting ??= this.launch().catch((error) => { this.starting = undefined; throw error })
    this.context = await this.starting
    this.page ??= this.context.pages()[0] ?? (await this.context.newPage())
    return this.page
  }

  private async launch(): Promise<BrowserContext> {
    clearStaleLock(this.profileDir)
    const executable = cachedChromium()
    const context = await chromium.launchPersistentContext(this.profileDir, {
      headless: true, executablePath: executable, viewport: VIEWPORT, userAgent: plainUserAgent(executable ?? chromium.executablePath()),
    })
    context.setDefaultTimeout(ACTION_TIMEOUT_MS)
    context.setDefaultNavigationTimeout(NAV_TIMEOUT_MS)
    // Every request the browser makes (pages, clicks, images, scripts) is checked: nothing local or private.
    if (!this.allowPrivate) await context.route('**/*', async (route) => {
      let host = ''
      try { host = new URL(route.request().url()).hostname } catch { return route.abort() }
      if (!/^(https?|data|blob):/.test(route.request().url())) return route.abort()
      if (host && (await this.blocked(host))) return route.abort('blockedbyclient')
      return route.continue()
    })
    // WebSockets get the same check.
    if (!this.allowPrivate) await context.routeWebSocket('**', async (ws) => {
      let host = ''
      try { host = new URL(ws.url()).hostname } catch { return ws.close() }
      if (!host || (await this.blocked(host))) return ws.close()
      ws.connectToServer()
    })
    return context
  }

  private async view(): Promise<PageView> {
    const page = await this.current()
    await page.waitForLoadState('domcontentloaded').catch(() => {})
    const text = (await page.innerText('body').catch(() => '')).replace(/\n{3,}/g, '\n\n').slice(0, PAGE_TEXT_CHARS)
    return { url: page.url(), title: await page.title(), text }
  }

  async open(url: string): Promise<PageView> {
    if (!/^https?:\/\//i.test(url)) throw new Error('only http and https pages can be opened')
    try {
      await (await this.current()).goto(url)
    } catch (error) {
      // A cold start can fail once; start the browser fresh and try again. A blocked address is not retried.
      if (String(error).includes('ERR_BLOCKED_BY_CLIENT')) throw error
      await this.close()
      await (await this.current()).goto(url)
    }
    return this.view()
  }

  /** The visible button or link with exactly this text, or failing that the element showing exactly it. */
  private async target(label: string): Promise<Locator> {
    const page = await this.current()
    for (const role of ['button', 'link'] as const) {
      const hit = page.getByRole(role, { name: label, exact: true }).first()
      if (await hit.isVisible().catch(() => false)) return hit
    }
    return page.getByText(label, { exact: true }).first()
  }

  /** What clicking this would really do, judged on the element itself, not the words the model used. */
  async check(label: string): Promise<ClickCheck> {
    const el = await this.target(label)
    return el.evaluate((node) => {
      const n = node as HTMLElement & { type?: string; form?: HTMLFormElement | null; value?: string }
      const name = (n.getAttribute('aria-label') || n.innerText || n.value || '').trim().slice(0, 120)
      const form = n.form ?? n.closest('form')
      const submits = Boolean(form) && (n.tagName === 'BUTTON' ? (n.type ?? 'submit') === 'submit' : n.type === 'submit')
      const dataForm = Boolean(form) && (form!.method.toLowerCase() === 'post' || Boolean(form!.querySelector('input[type=password], [autocomplete^=cc-], [autocomplete=one-time-code]')))
      return { name, sendsForm: submits && dataForm }
    })
  }

  async click(label: string): Promise<PageView> {
    await (await this.target(label)).click()
    return this.view()
  }

  /** The field with exactly this label or placeholder. */
  private async field(field: string): Promise<Locator> {
    const page = await this.current()
    const byLabel = page.getByLabel(field, { exact: true }).first()
    return (await byLabel.isVisible().catch(() => false)) ? byLabel : page.getByPlaceholder(field, { exact: true }).first()
  }

  /** Whether a field holds a secret, judged on the input itself (password, card, one-time code). */
  async checkField(field: string): Promise<{ secret: boolean }> {
    return (await this.field(field)).evaluate((node) => {
      const i = node as HTMLInputElement
      const hint = `${i.type} ${i.autocomplete} ${i.name} ${i.id}`.toLowerCase()
      return { secret: i.type === 'password' || /cc-|one-time-code|card|cvv|cvc|otp|pin\b/.test(hint) }
    })
  }

  async type(field: string, text: string): Promise<PageView> {
    await (await this.field(field)).fill(text)
    return this.view()
  }

  async read(): Promise<PageView> { return this.view() }

  // The user's own input during a handover. Positions are 0 to 1 across the visible page.
  async userClick(x: number, y: number): Promise<void> { await (await this.current()).mouse.click(x * VIEWPORT.width, y * VIEWPORT.height) }
  async userType(text: string): Promise<void> { await (await this.current()).keyboard.type(text) }
  async userKey(key: string): Promise<void> { await (await this.current()).keyboard.press(key === 'Space' ? ' ' : key) }
  async userScroll(dy: number): Promise<void> { await (await this.current()).mouse.wheel(0, dy) }

  async screenshot(): Promise<Buffer> { return (await this.current()).screenshot({ type: 'jpeg', quality: 60 }) }

  async close(): Promise<void> {
    const starting = this.starting
    this.starting = undefined; this.context = undefined; this.page = undefined
    await (await starting?.catch(() => undefined))?.close()
  }
}
