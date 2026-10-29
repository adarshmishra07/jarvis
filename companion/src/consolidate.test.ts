import { test } from 'node:test'
import assert from 'node:assert/strict'
import { openDb, insertExtraction, search, type Extraction } from './db.ts'
import { consolidate, isNightlyDue } from './consolidate.ts'

const ex = (over: Partial<Extraction>): Extraction => ({
  keep: true, reason: '', sensitivity: 'none', context: 'company', summary: '', entities: [], edges: [], action_items: [], ...over,
})

/** Fake Haiku: answers the duplicate-notes and same-entity questions with the given JSON, and records what it saw. */
function haiku(notes: object, entities: object) {
  const seen: string[] = []
  const fetch = (async (_u: string, init: RequestInit = {}) => {
    const body = JSON.parse(String(init.body))
    seen.push(String(body.system))
    const reply = String(body.system).includes('duplicate notes') ? notes : entities
    return new Response(JSON.stringify({ content: [{ type: 'text', text: JSON.stringify(reply) }] }), { status: 200 })
  }) as unknown as typeof fetch
  return { seen, deps: { fetch, apiKey: 'k' } }
}

test('duplicate notes are marked replaced (never deleted), the newest kept, and every change is logged', async () => {
  const db = openDb(':memory:')
  const a = insertExtraction(db, 'a', 'Orbit API launches Friday.', ex({ summary: 'Orbit API launches Friday' }))!
  const b = insertExtraction(db, 'b', 'The Orbit API launch is on Friday.', ex({ summary: 'Orbit API launch Friday' }))!
  const { deps } = haiku({ duplicates: [{ keep: b, drop: [a, 999] }] }, { same: [] })
  const r = await consolidate(db, deps, { now: new Date('2026-10-23T03:30:00') })
  assert.equal(r.notesMerged, 1)
  assert.deepEqual(search(db, 'Orbit API', 5).map((h) => h.id), [b])
  assert.equal((db.prepare('SELECT count(*) AS n FROM segments').get() as { n: number }).n, 2, 'nothing deleted')
  const ops = db.prepare('SELECT op, detail FROM memory_ops').all() as { op: string; detail: string }[]
  assert.deepEqual(ops.map((o) => o.op), ['note_replaced'])
})

test('same-named people merge only when the model says so', async () => {
  const db = openDb(':memory:')
  insertExtraction(db, 'a', 'Ravi reviews Atlas.', ex({ summary: 'Ravi reviews Atlas', entities: [{ name: 'Ravi', type: 'person' }] }))
  insertExtraction(db, 'b', 'Ravi Kumar owns Orbit.', ex({ summary: 'Ravi Kumar owns Orbit', entities: [{ name: 'Ravi Kumar', type: 'person' }] }))
  const ids = Object.fromEntries((db.prepare('SELECT id, name FROM entities').all() as { id: number; name: string }[]).map((e) => [e.name, e.id]))
  const { seen, deps } = haiku({ duplicates: [] }, { same: [{ keep: ids['Ravi Kumar'], merge: [ids['Ravi']] }] })
  const r = await consolidate(db, deps, { now: new Date() })
  assert.equal(r.entitiesMerged, 1)
  assert.deepEqual((db.prepare('SELECT name FROM entities ORDER BY name').all() as { name: string }[]).map((e) => e.name), ['Ravi Kumar'])
  assert.ok(seen.some((s) => s.includes('same person')), 'the model was asked')
})

test('a name used in two spaces is never merged: the gym friend Ravi is not the colleague', async () => {
  const db = openDb(':memory:')
  insertExtraction(db, 'a', 'Ravi reviews Atlas.', ex({ summary: 'Ravi reviews Atlas', entities: [{ name: 'Ravi', type: 'person' }] }))
  insertExtraction(db, 'b', 'Ravi Kumar owns Orbit.', ex({ summary: 'Ravi Kumar owns Orbit', entities: [{ name: 'Ravi Kumar', type: 'person' }] }))
  insertExtraction(db, 'c', 'Ravi from the gym.', ex({ context: 'personal', summary: 'Gym friend Ravi', entities: [{ name: 'Ravi', type: 'person' }] }))
  const ids = Object.fromEntries((db.prepare('SELECT id, name FROM entities').all() as { id: number; name: string }[]).map((e) => [e.name, e.id]))
  const { deps } = haiku({ duplicates: [] }, { same: [{ keep: ids['Ravi Kumar'], merge: [ids['Ravi']] }] })
  const r = await consolidate(db, deps, { now: new Date() })
  assert.equal(r.entitiesMerged, 0)
  assert.deepEqual((db.prepare('SELECT name FROM entities ORDER BY name').all() as { name: string }[]).map((e) => e.name), ['Ravi', 'Ravi Kumar'])
})

test('a second run soon after does nothing new, and a run never exceeds its cap', async () => {
  const db = openDb(':memory:')
  for (let i = 0; i < 5; i++) insertExtraction(db, `n${i}`, `Atlas note ${i}.`, ex({ summary: `Atlas ${i}` }))
  const { deps } = haiku({ duplicates: [{ keep: 5, drop: [1, 2, 3, 4] }] }, { same: [] })
  const r = await consolidate(db, deps, { now: new Date(), maxChanges: 2 })
  assert.equal(r.notesMerged, 2)
  const again = await consolidate(db, deps, { now: new Date() })
  assert.equal(again.checked, 0, 'only notes saved since the last run are checked')
})

test('it runs once a night, between 2 and 5 am', () => {
  const at = (s: string) => new Date(s)
  assert.equal(isNightlyDue(at('2026-10-23T03:10:00'), null), true)
  assert.equal(isNightlyDue(at('2026-10-23T14:00:00'), null), false, 'not in the day')
  assert.equal(isNightlyDue(at('2026-10-23T03:40:00'), at('2026-10-23T03:10:00')), false, 'already ran tonight')
  assert.equal(isNightlyDue(at('2026-10-24T02:05:00'), at('2026-10-23T03:10:00')), true, 'next night')
})
