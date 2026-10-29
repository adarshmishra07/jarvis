import { test } from 'node:test'
import assert from 'node:assert/strict'
import { McpOAuth } from './oauth.ts'
import { isPrivateAddress } from './browser.ts'

/** Test hosts under .example do not resolve; treat them as public, everything else as the real check does. */
const isPrivate = async (h: string): Promise<boolean> => (h.endsWith('.example') ? false : isPrivateAddress(h))

/** A fake MCP server that wants OAuth, and its fake authorization server (Clerk-like). */
function world() {
  const log: string[] = []
  let issued = 0
  const fetch = (async (url: string, init: RequestInit = {}) => {
    const u = new URL(url)
    const json = (d: unknown, status = 200, headers: Record<string, string> = {}) => new Response(JSON.stringify(d), { status, headers: { 'content-type': 'application/json', ...headers } })
    if (u.host === 'mcp.example' && u.pathname === '/mcp') return json({ error: 'unauthorized' }, 401, { 'www-authenticate': 'Bearer resource_metadata="https://mcp.example/.well-known/oauth-protected-resource/mcp", scope="read offline_access"' })
    if (u.pathname === '/.well-known/oauth-protected-resource/mcp') return json({ resource: 'https://mcp.example/mcp', authorization_servers: ['https://auth.example'], scopes_supported: ['read', 'offline_access'] })
    if (u.host === 'auth.example' && u.pathname === '/.well-known/oauth-authorization-server')
      return json({ issuer: 'https://auth.example', authorization_endpoint: 'https://auth.example/authorize', token_endpoint: 'https://auth.example/token', registration_endpoint: 'https://auth.example/register', code_challenge_methods_supported: ['S256'] })
    if (u.pathname === '/register') { const b = JSON.parse(String(init.body)); log.push(`register ${b.redirect_uris[0].startsWith('http://127.0.0.1:')}`); return json({ client_id: 'client-1' }, 201) }
    if (u.pathname === '/token') {
      const form = new URLSearchParams(String(init.body))
      log.push(`token ${form.get('grant_type')} ${form.get('code_verifier') ? 'pkce' : ''} ${form.get('resource')}`)
      issued++
      return json({ access_token: `at-${issued}`, refresh_token: `rt-${issued}`, expires_in: form.get('grant_type') === 'refresh_token' ? 3600 : -10 })
    }
    return json({}, 404)
  }) as unknown as typeof fetch
  return { fetch, log }
}

test('detects that a server wants a sign-in, signs in with PKCE through a local callback, and keeps tokens in the store', async () => {
  const { fetch, log } = world()
  const store = new Map<string, string>()
  const oauth = new McpOAuth({ fetch, isPrivate, secrets: { get: (k) => store.get(k), set: (k, v) => { store.set(k, v) }, remove: (k) => { store.delete(k) } } })
  assert.equal(await oauth.needsSignIn('https://mcp.example/mcp'), true)
  const { url, done } = await oauth.signIn('zentro', 'https://mcp.example/mcp')
  const authorize = new URL(url)
  assert.equal(authorize.origin + authorize.pathname, 'https://auth.example/authorize')
  assert.equal(authorize.searchParams.get('code_challenge_method'), 'S256')
  assert.equal(authorize.searchParams.get('client_id'), 'client-1')
  assert.equal(authorize.searchParams.get('resource'), 'https://mcp.example/mcp')
  // The browser comes back to the local callback with the code.
  const back = await globalThis.fetch(`${authorize.searchParams.get('redirect_uri')}?code=c1&state=${authorize.searchParams.get('state')}`)
  assert.equal(back.status, 200)
  await done
  assert.deepEqual(log, ['register true', 'token authorization_code pkce https://mcp.example/mcp'])
  assert.ok(store.get('mcp-oauth:zentro')?.includes('rt-1'))
  // The first token was already expired, so asking for one refreshes it.
  assert.equal(await oauth.token('zentro'), 'at-2')
  assert.equal(log.at(-1), 'token refresh_token  https://mcp.example/mcp')
  assert.equal(await oauth.token('zentro'), 'at-2', 'a fresh token is reused')
})

test('a callback with the wrong state is rejected and nothing is stored', async () => {
  const { fetch } = world()
  const store = new Map<string, string>()
  const oauth = new McpOAuth({ fetch, isPrivate, secrets: { get: (k) => store.get(k), set: (k, v) => { store.set(k, v) }, remove: (k) => { store.delete(k) } } })
  const { url, done } = await oauth.signIn('x', 'https://mcp.example/mcp')
  const redirect = new URL(url).searchParams.get('redirect_uri')!
  const back = await globalThis.fetch(`${redirect}?code=c1&state=forged`)
  assert.equal(back.status, 400)
  await assert.rejects(done)
  assert.equal(store.size, 0)
})

test('sign-in details that point somewhere unsafe or do not match the server are refused', async () => {
  const store = { get: () => undefined, set: () => {}, remove: () => {} }
  const variant = (patch: { meta?: object; as?: object; header?: string }) => {
    const base = world().fetch
    return (async (url: string, init: RequestInit = {}) => {
      const u = new URL(url)
      if (patch.header && u.host === 'mcp.example' && u.pathname === '/mcp') return new Response('{}', { status: 401, headers: { 'www-authenticate': patch.header } })
      if (patch.meta && u.pathname === '/.well-known/oauth-protected-resource/mcp') return new Response(JSON.stringify(patch.meta))
      if (patch.as && u.pathname === '/.well-known/oauth-authorization-server') return new Response(JSON.stringify(patch.as))
      return base(url, init)
    }) as unknown as typeof fetch
  }
  const tryWith = (p: Parameters<typeof variant>[0]) => new McpOAuth({ fetch: variant(p), secrets: store, isPrivate }).signIn('x', 'https://mcp.example/mcp')
  await assert.rejects(tryWith({ header: 'Bearer resource_metadata="https://elsewhere.example/meta"' }), /same site/)
  await assert.rejects(tryWith({ meta: { resource: 'https://other.example/mcp', authorization_servers: ['https://auth.example'] } }), /different server/)
  await assert.rejects(tryWith({ meta: { resource: 'https://mcp.example/mcp', authorization_servers: ['https://127.0.0.1'] } }), /local/)
  await assert.rejects(tryWith({ as: { issuer: 'https://auth.example', authorization_endpoint: 'https://auth.example/authorize', token_endpoint: 'http://auth.example/token', registration_endpoint: 'https://auth.example/register' } }), /https/)
  await assert.rejects(tryWith({ as: { issuer: 'https://impostor.example', authorization_endpoint: 'https://auth.example/authorize', token_endpoint: 'https://auth.example/token', registration_endpoint: 'https://auth.example/register' } }), /issuer/)
})

test('sign-in never follows redirects, and the token address is checked again before a refresh', async () => {
  const seen: RequestInit[] = []
  const { fetch: base } = world()
  const fetch = (async (url: string, init: RequestInit = {}) => { seen.push(init); return base(url, init) }) as unknown as typeof fetch
  const store = new Map<string, string>([['mcp-oauth:old', JSON.stringify({ clientId: 'c', tokenEndpoint: 'https://127.0.0.1/token', resource: 'https://mcp.example/mcp', access: 'a', refresh: 'r', expiresAt: 0 })]])
  const oauth = new McpOAuth({ fetch, isPrivate, secrets: { get: (k) => store.get(k), set: (k, v) => { store.set(k, v) }, remove: (k) => { store.delete(k) } } })
  await oauth.signIn('x', 'https://mcp.example/mcp')
  assert.ok(seen.filter((i) => i.method !== 'POST' || !String(i.body ?? '').includes('initialize')).every((i) => i.redirect === 'error'), 'no sign-in request follows a redirect')
  await assert.rejects(oauth.token('old'), /local or private/)
})
