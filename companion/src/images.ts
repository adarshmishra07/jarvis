import { isPrivateAddress } from './browser.ts'

// Images in answers. The app has no internet, so the companion fetches them, and only safely: links that came from
// what Jarvis actually read (tool results, pages, connectors) load on their own; any other link waits for the user's
// click, because loading an image a page planted could carry data out in its address.

const MAX_BYTES = 5 * 1024 * 1024
const TIMEOUT_MS = 10_000
const MAX_TRUSTED = 500
const TYPES = new Set(['image/png', 'image/jpeg', 'image/gif', 'image/webp'])

export type ImageResult = { status: 'ok'; mime: string; data: string } | { status: 'ask' } | { status: 'blocked'; reason: string }

/** Image links (by extension) in a piece of text. */
export function imageUrlsIn(text: string): string[] {
  const found = text.match(/https:\/\/[^\s"'<>)\]]+\.(?:png|jpe?g|gif|webp)(?:\?[^\s"'<>)\]]*)?/gi) ?? []
  return [...new Set(found.map((u) => u.replace(/[.,;:!]+$/, '')))] // a sentence's punctuation is not part of the link
}

export class ImageGate {
  private readonly trusted = new Set<string>()
  private readonly fetch: typeof fetch
  private readonly isPrivate: (host: string) => Promise<boolean>

  constructor(fetchImpl: typeof fetch, isPrivate: (host: string) => Promise<boolean> = isPrivateAddress) { this.fetch = fetchImpl; this.isPrivate = isPrivate }

  /** A link that came from a source Jarvis read: it may load without asking. */
  trust(url: string): void {
    if (this.trusted.size >= MAX_TRUSTED) this.trusted.delete(this.trusted.values().next().value!)
    this.trusted.add(url)
  }

  /** Trusts image links in a connector's result only when they are on that connector's own site (its storage, its CDN):
   * links inside emails or documents it returned were written by someone else and still need a click. */
  trustFrom(serverUrl: string, text: string): void {
    const site = (h: string): string => h.toLowerCase().split('.').slice(-2).join('.')
    const own = site(new URL(serverUrl).hostname)
    for (const url of imageUrlsIn(text)) { try { if (site(new URL(url).hostname) === own) this.trust(url) } catch { /* not an address */ } }
  }

  trustedList(): string[] { return [...this.trusted] }

  async load(url: string, userClicked: boolean): Promise<ImageResult> {
    let u: URL
    try { u = new URL(url) } catch { return { status: 'blocked', reason: 'not an address' } }
    if (u.protocol !== 'https:' || u.username || u.password) return { status: 'blocked', reason: 'only plain https images' }
    if (!userClicked && !this.trusted.has(u.href) && !this.trusted.has(url)) return { status: 'ask' }
    if (await this.isPrivate(u.hostname)) return { status: 'blocked', reason: 'local or private address' }
    try {
      const r = await this.fetch(u.href, { redirect: 'error', signal: AbortSignal.timeout(TIMEOUT_MS) })
      const mime = (r.headers.get('content-type') ?? '').split(';')[0].trim().toLowerCase()
      if (!r.ok || !TYPES.has(mime)) return { status: 'blocked', reason: 'not an image' }
      if (Number(r.headers.get('content-length') ?? 0) > MAX_BYTES) return { status: 'blocked', reason: 'too large' }
      // Count bytes as they arrive and stop at the cap, so a huge file is never fully downloaded.
      const chunks: Uint8Array[] = []
      let size = 0
      const reader = r.body!.getReader()
      for (;;) {
        const { done, value } = await reader.read()
        if (done) break
        size += value.length
        if (size > MAX_BYTES) { await reader.cancel(); return { status: 'blocked', reason: 'too large' } }
        chunks.push(value)
      }
      return { status: 'ok', mime, data: Buffer.concat(chunks).toString('base64') }
    } catch { return { status: 'blocked', reason: 'could not load' } }
  }
}
