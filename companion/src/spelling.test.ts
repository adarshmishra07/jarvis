import { test } from 'node:test'
import assert from 'node:assert/strict'
import { openDb, insertExtraction, search, deleteSegment } from './db.ts'
import { fixSpelling, respellMemory, mergeAliases } from './spelling.ts'

const map = { zentra: 'Zentro' }

test('fixes whole words in any case and leaves other words alone', () => {
  assert.equal(fixSpelling('When is the Zentra launch? zentra, ZENTRA.', map), 'When is the Zentro launch? Zentro, Zentro.')
  assert.equal(fixSpelling('zentray roads', map), 'zentray roads')
  assert.equal(fixSpelling('no change', {}), 'no change')
})

test('respells stored notes, keeps search in step, and merges a misspelled entity into the right one', () => {
  const db = openDb(':memory:')
  const base = { keep: true, reason: '', sensitivity: 'none', context: 'company' as const, edges: [], action_items: [] }
  insertExtraction(db, 'a', 'Zentro ships Friday.', { ...base, summary: 'Zentro ships', entities: [{ name: 'Zentro', type: 'project' }] })
  insertExtraction(db, 'b', 'The zentra demo went well.', { ...base, summary: 'zentra demo', entities: [{ name: 'Zentra', type: 'project' }] })
  assert.equal(respellMemory(db, map), 1)
  assert.equal((db.prepare("SELECT text FROM segments WHERE clip = 'b'").get() as { text: string }).text, 'The Zentro demo went well.')
  assert.equal(search(db, 'zentra', 5).length, 0)
  assert.equal(search(db, 'Zentro demo', 5)[0].clip, 'b')
  const names = (db.prepare('SELECT name FROM entities').all() as { name: string }[]).map((r) => r.name)
  assert.deepEqual(names, ['Zentro'])
  assert.equal((db.prepare('SELECT count(*) AS n FROM mentions').get() as { n: number }).n, 2)
})

test('every rewrite keeps the old text so it can be undone', () => {
  const db = openDb(':memory:')
  const base = { keep: true, reason: '', sensitivity: 'none', context: 'company' as const, edges: [], action_items: [], entities: [] }
  insertExtraction(db, 'b', 'The zentra demo went well.', { ...base, summary: 'zentra demo' })
  respellMemory(db, map)
  const log = db.prepare('SELECT old_text, old_summary FROM respell_log').all() as { old_text: string; old_summary: string }[]
  assert.deepEqual(log.map((r) => [r.old_text, r.old_summary]), [['The zentra demo went well.', 'zentra demo']])
  deleteSegment(db, (db.prepare("SELECT id FROM segments WHERE clip = 'b'").get() as { id: number }).id)
  assert.equal((db.prepare('SELECT count(*) AS n FROM respell_log').get() as { n: number }).n, 0, 'forgetting a note forgets its old text too')
})

test('aliases merge whole entities into one node, keeping every link', () => {
  const db = openDb(':memory:')
  const base = { keep: true, reason: '', sensitivity: 'none', context: 'company' as const, action_items: [] }
  insertExtraction(db, 'a', 'I lead Atlas.', { ...base, summary: 'leads Atlas', entities: [{ name: 'User', type: 'person' }, { name: 'Atlas', type: 'project' }], edges: [{ source: 'User', relation: 'leads', target: 'Atlas' }] })
  insertExtraction(db, 'b', 'Asha reports to Ravi Kumar.', { ...base, summary: 'Asha reports to Ravi', entities: [{ name: 'Ravi Kumar', type: 'person' }, { name: 'Asha', type: 'person' }], edges: [{ source: 'Asha', relation: 'reports_to', target: 'Ravi Kumar' }] })
  assert.equal(mergeAliases(db, { user: 'Ravi Kumar', me: 'Ravi Kumar' }), 1)
  const names = (db.prepare('SELECT name FROM entities ORDER BY name').all() as { name: string }[]).map((r) => r.name)
  assert.deepEqual(names, ['Asha', 'Atlas', 'Ravi Kumar'])
  const edges = db.prepare('SELECT a.name AS s, b.name AS t FROM edges e JOIN entities a ON a.id = e.src JOIN entities b ON b.id = e.dst ORDER BY s').all() as { s: string; t: string }[]
  assert.deepEqual(edges.map((e) => `${e.s}->${e.t}`), ['Asha->Ravi Kumar', 'Ravi Kumar->Atlas'])
  assert.equal(mergeAliases(db, { user: 'Ravi Kumar' }), 0, 'nothing left to merge')
})

test('an alias with no existing target just renames the node', () => {
  const db = openDb(':memory:')
  insertExtraction(db, 'a', 'Me and Atlas.', { keep: true, reason: '', sensitivity: 'none', context: 'company', summary: 's', entities: [{ name: 'Me', type: 'person' }], edges: [], action_items: [] })
  mergeAliases(db, { me: 'Ravi Kumar' })
  assert.deepEqual((db.prepare('SELECT name, key FROM entities').all() as object[]).map((r) => ({ ...r })), [{ name: 'Ravi Kumar', key: 'ravi kumar' }])
})

test('a fix whose right form contains the wrong one is stable: repeating it changes nothing', () => {
  const m = { zentro: 'Zentro AI' }
  assert.equal(fixSpelling('We ship Zentro next week, Zentro AI too.', m), 'We ship Zentro AI next week, Zentro AI too.')
  assert.equal(fixSpelling(fixSpelling('what is Zentro AI', m), m), 'what is Zentro AI')
  const db = openDb(':memory:')
  insertExtraction(db, 'a', 'We ship Zentro next week.', { keep: true, reason: '', sensitivity: 'none', context: 'company', summary: 'Zentro ships', entities: [{ name: 'Zentro', type: 'project' }], edges: [], action_items: [] })
  for (let i = 0; i < 3; i++) respellMemory(db, m)
  assert.equal((db.prepare("SELECT text FROM segments WHERE clip = 'a'").get() as { text: string }).text, 'We ship Zentro AI next week.')
  assert.deepEqual((db.prepare('SELECT name FROM entities').all() as { name: string }[]).map((r) => r.name), ['Zentro AI'])
  assert.equal((db.prepare('SELECT count(*) AS n FROM respell_log').get() as { n: number }).n, 1, 'only the first pass changed anything')
})
