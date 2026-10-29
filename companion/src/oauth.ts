import http from 'node:http'
import { createHash, randomBytes } from 'node:crypto'
import { isPrivateAddress } from './browser.ts'

// Sign-in for MCP servers that use OAuth (the MCP authorization spec): find the server's sign-in service, register
// this app with it, open the login page, take the code on a one-time local callback (PKCE), and keep the tokens in
// the Keychain, refreshing them when they expire.

const CALLBACK_TIMEOUT_MS = 5 * 60_000
const REFRESH_MARGIN_MS = 60_000

export interface SecretStore { get(k: string): string | undefined; set(k: string, v: string): void; remove(k: string): void }
interface Saved { clientId: string; tokenEndpoint: string; resource: string; access: string; refresh?: string; expiresAt: number }

const b64url = (b: Buffer): string => b.toString('base64url')
const account = (name: string): string => `mcp-oauth:${name}`

export class McpOAuth {
  private readonly fetch: typeof fetch
  private readonly secrets: SecretStore
  private readonly isPrivate: (host: string) => Promise<boolean>

  constructor(deps: { fetch: typeof fetch; secrets: SecretStore; isPrivate?: (host: string) => Promise<boolean> }) {
    this.fetch = deps.fetch; this.secrets = deps.secrets; this.isPrivate = deps.isPrivate ?? isPrivateAddress
  }

  /** Sign-in requests never follow redirects: a redirect could lead somewhere the address check never saw.
   * ponytail: DNS rebinding between the check and the connection remains; pin IPs with an undici dispatcher to close it. */
  private async json(url: string, init?: RequestInit): Promise<any> {
    const r = await this.fetch(url, { ...init, redirect: 'error' })
    if (!r.ok) throw new Error(`sign-in step failed: ${new URL(url).pathname} (${r.status})`)
    return r.json()
  }

  /** The server answered without a token by asking for one: it wants a sign-in. Returns where to learn how. */
  private async challenge(serverUrl: string): Promise<string | null> {
    const r = await this.fetch(serverUrl, {
      method: 'POST', headers: { 'content-type': 'application/json', accept: 'application/json, text/event-stream' },
      body: JSON.stringify({ jsonrpc: '2.0', id: 1, method: 'initialize', params: { protocolVersion: '2025-06-18', capabilities: {}, clientInfo: { name: 'agent-pikachu', version: '1' } } }),
    })
    if (r.status !== 401) return null
    const header = r.headers.get('www-authenticate') ?? ''
    return header.match(/resource_metadata="([^"]+)"/)?.[1] ?? new URL('/.well-known/oauth-protected-resource', serverUrl).href
  }

  /** Every sign-in address must be https and on the public internet. */
  private async safe(url: string, what: string): Promise<string> {
    let u: URL
    try { u = new URL(url) } catch { throw new Error(`${what} is not a valid address`) }
    if (u.protocol !== 'https:') throw new Error(`${what} must use https`)
    if (await this.isPrivate(u.hostname)) throw new Error(`${what} is on a local or private address`)
    return u.href
  }

  async needsSignIn(serverUrl: string): Promise<boolean> { return (await this.challenge(serverUrl)) !== null }

  /** Starts a sign-in: returns the login page to open, and a promise that settles when the browser comes back. */
  async signIn(name: string, serverUrl: string): Promise<{ url: string; done: Promise<void> }> {
    const metaUrl = await this.challenge(serverUrl)
    if (!metaUrl) throw new Error('this server does not ask for a sign-in')
    // The details must come from the server's own site, describe this very server, and name a public https service.
    if (new URL(metaUrl).origin !== new URL(serverUrl).origin) throw new Error('the sign-in details are not on the same site as the server')
    const resourceMeta = await this.json(await this.safe(metaUrl, 'the sign-in details'))
    const same = (a: unknown, b: string): boolean => String(a ?? '').replace(/\/$/, '') === b.replace(/\/$/, '')
    if (!same(resourceMeta.resource, serverUrl)) throw new Error('the sign-in details are for a different server')
    const issuer = await this.safe(String(resourceMeta.authorization_servers?.[0] ?? ''), 'the sign-in service')
    const as = await this.json(new URL('/.well-known/oauth-authorization-server', issuer).href)
      .catch(() => this.json(new URL('/.well-known/openid-configuration', issuer).href))
    if (!same(as.issuer, issuer)) throw new Error('the sign-in service issuer does not match')
    if (!as.registration_endpoint) throw new Error('the sign-in service does not let apps register themselves')
    for (const [key, what] of [['authorization_endpoint', 'the login page'], ['token_endpoint', 'the token address'], ['registration_endpoint', 'the registration address']] as const)
      as[key] = await this.safe(String(as[key] ?? ''), what)
    const scope = ((resourceMeta.scopes_supported ?? []) as string[]).join(' ')

    // A one-time callback on this Mac only; the port is chosen now, so the app registers with this exact address.
    const verifier = b64url(randomBytes(32))
    const state = b64url(randomBytes(16))
    let settle!: (e?: Error) => void
    const done = new Promise<void>((resolve, reject) => { settle = (e) => (e ? reject(e) : resolve()) })
    done.catch(() => {}) // a failed sign-in is reported to whoever awaits it, never as a crash
    const server = http.createServer()
    await new Promise<void>((r) => server.listen(0, '127.0.0.1', r))
    const redirect = `http://127.0.0.1:${(server.address() as { port: number }).port}/callback`
    const close = (): void => { server.close(); clearTimeout(timer) }
    const timer = setTimeout(() => { close(); settle(new Error('sign-in timed out')) }, CALLBACK_TIMEOUT_MS)
    server.unref(); timer.unref() // a pending sign-in never keeps the process alive on its own

    const reg = await this.json(as.registration_endpoint, {
      method: 'POST', headers: { 'content-type': 'application/json' },
      body: JSON.stringify({ client_name: 'Jarvis', redirect_uris: [redirect], grant_types: ['authorization_code', 'refresh_token'], response_types: ['code'], token_endpoint_auth_method: 'none' }),
    }).catch((e) => { close(); throw e })
    const clientId = String(reg.client_id)

    server.on('request', async (req, res) => {
      const u = new URL(req.url ?? '/', redirect)
      if (u.pathname !== '/callback') { res.writeHead(404).end(); return }
      const page = (status: number, text: string): void => { res.writeHead(status, { 'content-type': 'text/html; charset=utf-8' }).end(`<p style="font:16px system-ui">${text}</p>`) }
      if (u.searchParams.get('state') !== state || !u.searchParams.get('code')) {
        page(400, 'Sign-in failed. You can close this tab.'); close(); settle(new Error('sign-in was not completed')); return
      }
      try {
        const t = await this.exchange(as.token_endpoint, { grant_type: 'authorization_code', code: u.searchParams.get('code')!, redirect_uri: redirect, client_id: clientId, code_verifier: verifier, resource: serverUrl })
        this.save(name, { clientId, tokenEndpoint: as.token_endpoint, resource: serverUrl, ...t })
        page(200, 'Signed in. You can close this tab and go back to Jarvis.')
        close(); settle()
      } catch (e) { page(400, 'Sign-in failed. You can close this tab.'); close(); settle(e as Error) }
    })

    const auth = new URL(as.authorization_endpoint)
    for (const [k, v] of Object.entries({ response_type: 'code', client_id: clientId, redirect_uri: redirect, code_challenge: b64url(createHash('sha256').update(verifier).digest()),
      code_challenge_method: 'S256', state, resource: serverUrl, ...(scope ? { scope } : {}) })) auth.searchParams.set(k, v)
    return { url: auth.href, done }
  }

  private async exchange(tokenEndpoint: string, form: Record<string, string>): Promise<Pick<Saved, 'access' | 'refresh' | 'expiresAt'>> {
    const t = await this.json(tokenEndpoint, { method: 'POST', headers: { 'content-type': 'application/x-www-form-urlencoded' }, body: new URLSearchParams(form).toString() })
    if (typeof t.access_token !== 'string') throw new Error('no token came back')
    return { access: t.access_token, refresh: t.refresh_token, expiresAt: Date.now() + Number(t.expires_in ?? 3600) * 1000 }
  }

  private save(name: string, s: Saved): void { this.secrets.set(account(name), JSON.stringify(s)) }

  /** A valid access token for this server, refreshed when about to expire; undefined when never signed in. */
  async token(name: string): Promise<string | undefined> {
    const raw = this.secrets.get(account(name))
    if (!raw) return undefined
    const s = JSON.parse(raw) as Saved
    if (Date.now() < s.expiresAt - REFRESH_MARGIN_MS) return s.access
    if (!s.refresh) return undefined
    await this.safe(s.tokenEndpoint, 'the token address')
    const t = await this.exchange(s.tokenEndpoint, { grant_type: 'refresh_token', refresh_token: s.refresh, client_id: s.clientId, resource: s.resource })
    this.save(name, { ...s, ...t, refresh: t.refresh ?? s.refresh })
    return t.access
  }

  forget(name: string): void { this.secrets.remove(account(name)) }
}
