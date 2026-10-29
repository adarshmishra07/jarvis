import { test } from 'node:test'
import assert from 'node:assert/strict'
import { McpServer } from './mcp.ts'
import { listApps, connectApp, removeApp, renameApp, APPS } from './apps.ts'

/** Fake Composio Connect: answers COMPOSIO_MANAGE_CONNECTIONS like the real one. */
function fake() {
  const calls: any[] = []
  const fetch = (async (_u: string, init: RequestInit = {}) => {
    const msg = JSON.parse(String(init.body))
    if (!msg.id) return new Response('', { status: 202 })
    if (msg.method !== 'tools/call') return new Response(JSON.stringify({ jsonrpc: '2.0', id: msg.id, result: {} }))
    calls.push(msg.params.arguments)
    const t = msg.params.arguments.toolkits
    const data = t[0].action === 'list'
      ? { results: Object.fromEntries(t.map((k: { name: string }) => [k.name, { toolkit: k.name, status: 'x', accounts: k.name === 'gmail'
          ? [{ id: 'a1', status: 'ACTIVE', alias: 'work' }, { id: 'a2', status: 'INITIATED' }] : k.name === 'linear' ? [{ id: 'l1', status: 'INITIATED' }]
          : k.name === 'googlecalendar' ? [{ id: 'c1', status: 'ACTIVE', user_info: { summary: 'me@example.com', items: [{ summary: 'Private meeting' }] } }] : [] }])) }
      : t[0].action === 'add' ? { results: { [t[0].name]: { redirect_url: 'https://connect.composio.dev/link/lk_x' } } } : { results: {} }
    return new Response(JSON.stringify({ jsonrpc: '2.0', id: msg.id, result: { content: [{ type: 'text', text: JSON.stringify({ successful: true, data }) }] } }))
  }) as unknown as typeof fetch
  return { calls, server: new McpServer({ name: 'composio', url: 'https://connect.composio.dev/mcp', headers: {} }, fetch) }
}

test('the app list shows every app with its accounts and whether it is connected', async () => {
  const { server, calls } = fake()
  const apps = await listApps(server)
  assert.equal(apps.length, APPS.length)
  const gmail = apps.find((a) => a.slug === 'gmail')!
  assert.equal(gmail.connected, true)
  assert.deepEqual(gmail.accounts, [{ id: 'a1', status: 'ACTIVE', alias: 'work', who: '' }, { id: 'a2', status: 'INITIATED', alias: '', who: '' }])
  // Which account it is (the email), and nothing else from what the app sent along (events stay out).
  assert.deepEqual(apps.find((a) => a.slug === 'googlecalendar')!.accounts, [{ id: 'c1', status: 'ACTIVE', alias: '', who: 'me@example.com' }])
  assert.equal(apps.find((a) => a.slug === 'slack')!.connected, false)
  assert.equal(apps.find((a) => a.slug === 'linear')!.connected, false, 'a sign-in that never finished is not connected')
  assert.equal(calls.length, 1, 'one call lists them all')
  assert.ok(calls[0].toolkits.every((k: { action: string }) => k.action === 'list'))
})

test('connecting gives a sign-in link, with an optional label for a second account; removing names the account', async () => {
  const { server, calls } = fake()
  assert.equal(await connectApp(server, 'gmail', 'personal'), 'https://connect.composio.dev/link/lk_x')
  assert.deepEqual(calls[0].toolkits, [{ name: 'gmail', action: 'add', alias: 'personal' }])
  await removeApp(server, 'gmail', 'a2')
  assert.deepEqual(calls[1].toolkits, [{ name: 'gmail', action: 'remove', account_id: 'a2' }])
  await assert.rejects(connectApp(server, 'not-in-the-list'))
})

test('an account can be renamed with a label; every app has a description and a group', async () => {
  const { server, calls } = fake()
  await renameApp(server, 'gmail', 'a1', 'work')
  assert.deepEqual(calls[0].toolkits, [{ name: 'gmail', action: 'rename', account_id: 'a1', alias: 'work' }])
  await assert.rejects(renameApp(server, 'gmail', 'a1', ''))
  assert.ok(APPS.every((a) => a.about.length > 10))
  assert.deepEqual(APPS.filter((a) => a.group === 'Google Workspace').map((a) => a.slug), ['gmail', 'googlecalendar', 'googledrive', 'googledocs', 'googlesheets'])
})
