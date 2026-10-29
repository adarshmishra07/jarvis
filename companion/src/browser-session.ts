import type { PageView } from './browser.ts'

// What the app shows of Jarvis's browser: live frames, and who is in control. While Jarvis works the user can only
// watch; when Jarvis asks for help (a login, a code), the user drives the page until they press continue.

export type BrowserState = 'idle' | 'working' | 'needsUser'
export interface BrowserEvent { state: BrowserState; reason?: string; url?: string; frame?: string }

export interface SessionBrowser {
  screenshot(): Promise<Buffer>
  read(): Promise<PageView>
  userClick(x: number, y: number): Promise<void>
  userType(text: string): Promise<void>
  userKey(key: string): Promise<void>
  userScroll(dy: number): Promise<void>
}

export type UserInput = { kind: 'click'; x: number; y: number } | { kind: 'type'; text: string } | { kind: 'key'; key: string } | { kind: 'scroll'; dy: number }

/** Keys the user may press in the page: editing and moving keys only, never shortcuts. */
const KEYS = new Set(['Enter', 'Tab', 'Backspace', 'Delete', 'Escape', 'ArrowUp', 'ArrowDown', 'ArrowLeft', 'ArrowRight', 'Home', 'End', 'PageUp', 'PageDown', 'Space'])
const MAX_TYPE = 500
const MAX_REPLY = 1000

export class BrowserSession {
  private state: BrowserState = 'idle'
  private reason = ''
  private readonly watchers = new Set<(e: BrowserEvent) => void>()
  private timer?: NodeJS.Timeout
  private waiting?: { resolve: (note: string) => void; timer: NodeJS.Timeout }
  private readonly browser: SessionBrowser
  private readonly frameMs: number
  private readonly handoverMs: number

  constructor(browser: SessionBrowser, opts: { frameMs?: number; handoverMs?: number } = {}) {
    this.browser = browser; this.frameMs = opts.frameMs ?? 900; this.handoverMs = opts.handoverMs ?? 10 * 60_000
  }

  /** Starts receiving events; returns a function that stops them. The current state is sent at once. */
  watch(fn: (e: BrowserEvent) => void): () => void {
    this.watchers.add(fn)
    fn({ state: this.state, reason: this.reason || undefined })
    return () => { this.watchers.delete(fn) }
  }

  private emit(e: BrowserEvent): void { for (const w of this.watchers) w(e) }

  private async frame(): Promise<void> {
    if (!this.watchers.size || this.state === 'idle') return
    try {
      const [shot, page] = await Promise.all([this.browser.screenshot(), this.browser.read()])
      this.emit({ state: this.state, reason: this.reason || undefined, url: page.url, frame: shot.toString('base64') })
    } catch { /* the page is between loads: the next frame will catch up */ }
  }

  private set(state: BrowserState, reason = ''): void {
    this.state = state; this.reason = reason
    this.emit({ state, reason: reason || undefined })
    if (state === 'idle') { clearInterval(this.timer); this.timer = undefined; return }
    this.timer ??= setInterval(() => void this.frame(), this.frameMs)
    this.timer.unref()
    void this.frame()
  }

  working(): void { if (this.state !== 'needsUser') this.set('working') }

  /** The session is over (the answer finished): any open handover ends too. */
  idle(): void { this.resume(''); this.set('idle') }

  /** Hands control to the user and waits until they press continue (or nobody answers). */
  askUser(reason: string): Promise<string> {
    this.resume('')
    this.set('needsUser', reason.slice(0, 200))
    return new Promise((resolve) => {
      const timer = setTimeout(() => { this.waiting = undefined; this.set('working'); resolve('The user did not respond in time. Stop and tell them what you needed.') }, this.handoverMs)
      timer.unref()
      this.waiting = { resolve, timer }
    })
  }

  /** The user replied in the chat (or pressed continue): Jarvis carries on with what they sent. */
  resume(note: string): void {
    const w = this.waiting
    if (!w) return
    this.waiting = undefined
    clearTimeout(w.timer)
    this.set('working')
    w.resolve(note.trim() ? `The user replied: ${note.trim().slice(0, MAX_REPLY)}` : 'The user finished in the browser and handed control back.')
  }

  /** The user's own clicks and keys, only while it is their turn. Coordinates are 0 to 1 across the page. */
  async input(i: UserInput): Promise<void> {
    if (this.state !== 'needsUser') throw new Error('Jarvis is in control right now')
    if (i.kind === 'click') {
      if (!(i.x >= 0 && i.x <= 1 && i.y >= 0 && i.y <= 1)) throw new Error('click outside the page')
      await this.browser.userClick(i.x, i.y)
    } else if (i.kind === 'type') {
      await this.browser.userType(String(i.text).slice(0, MAX_TYPE))
    } else if (i.kind === 'key') {
      if (!KEYS.has(i.key)) throw new Error('that key is not allowed')
      await this.browser.userKey(i.key)
    } else if (i.kind === 'scroll') {
      await this.browser.userScroll(Math.max(-3000, Math.min(3000, Number(i.dy) || 0)))
    }
    void this.frame()
  }
}
