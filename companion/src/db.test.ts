import { test } from 'node:test'
import assert from 'node:assert/strict'
import { openDb, insertExtraction, deleteSegment, search, graphData, purgeBlocked, supersede, listNotes, listTodos, setTodoStatus, restoreNote, type Extraction } from './db.ts'

const extraction = (over: Partial<Extraction> = {}): Extraction => ({
  keep: true,
  reason: 'work update',
  sensitivity: 'none',
  context: 'professional',
  summary: 'Launch tomorrow; Priya owns pricing.',
  entities: [
    { name: 'Priya', type: 'person' },
    { name: 'Launch', type: 'project' },
  ],
  edges: [{ source: 'Priya', relation: 'owns', target: 'Launch' }],
  action_items: [{ text: 'Finish pricing page', owner: 'Priya' }],
  ...over,
})

const count = (db: ReturnType<typeof openDb>, table: string): number =>
  (db.prepare(`SELECT count(*) AS n FROM ${table}`).get() as { n: number }).n

test('insert stores segment, entities, edges, actions with provenance', () => {
  const db = openDb(':memory:')
  const id = insertExtraction(db, 'clip-01', 'Tomorrow is the launch and Priya owns pricing', extraction())
  assert.ok(id)
  assert.equal(count(db, 'segments'), 1)
  assert.equal(count(db, 'entities'), 2)
  assert.equal(count(db, 'edges'), 1)
  assert.equal(count(db, 'actions'), 1)
  assert.equal((db.prepare('SELECT segment_id FROM edges').get() as { segment_id: number }).segment_id, id)
})

test('same entity name in two segments reuses one entity, case-insensitively', () => {
  const db = openDb(':memory:')
  insertExtraction(db, 'a', 'one', extraction())
  insertExtraction(db, 'b', 'two', extraction({ entities: [{ name: 'priya', type: 'person' }], edges: [], action_items: [] }))
  assert.equal(count(db, 'entities'), 2)
})

test('keep=false stores no transcript text, only the clip id and reason', () => {
  const db = openDb(':memory:')
  const id = insertExtraction(db, 'secret', 'private chatter that must not be stored', extraction({ keep: false, reason: 'personal' }))
  assert.equal(id, null)
  assert.equal(count(db, 'segments'), 0)
  assert.equal(count(db, 'discarded'), 1)
  const dump = JSON.stringify(db.prepare('SELECT * FROM discarded').all())
  assert.ok(!dump.includes('private chatter'))
})

test('deleting a segment cascades to edges, actions, mentions, search index, and orphan entities', () => {
  const db = openDb(':memory:')
  const first = insertExtraction(db, 'a', 'Priya owns the launch pricing', extraction())!
  insertExtraction(db, 'b', 'Rahul reviews templates', extraction({
    summary: 'Rahul reviews templates',
    entities: [{ name: 'Rahul', type: 'person' }],
    edges: [],
    action_items: [],
  }))
  deleteSegment(db, first)
  assert.equal(count(db, 'segments'), 1)
  assert.equal(count(db, 'edges'), 0)
  assert.equal(count(db, 'actions'), 0)
  assert.equal(count(db, 'mentions'), 1)
  assert.deepEqual((db.prepare('SELECT name FROM entities').all() as { name: string }[]).map((r) => r.name), ['Rahul'])
  assert.equal(search(db, 'pricing', 5).length, 0)
})

test('search ranks matching segments and survives punctuation and Hindi', () => {
  const db = openDb(':memory:')
  insertExtraction(db, 'a', 'Nimbus CMS is connected to each environment', extraction({ summary: 'Nimbus CMS setup', entities: [], edges: [], action_items: [] }))
  insertExtraction(db, 'b', 'तो कल गुरुवार को लॉन्च का कॉल है', extraction({ summary: 'launch call on Thursday', entities: [], edges: [], action_items: [] }))
  assert.equal(search(db, 'nimbus?!', 5)[0].clip, 'a')
  assert.equal(search(db, 'लॉन्च', 5)[0].clip, 'b')
  assert.deepEqual(search(db, '"; DROP TABLE segments; --', 5), [])
})

test('search ignores filler words so a question made of them matches nothing', () => {
  const db = openDb(':memory:')
  insertExtraction(db, 'a', 'Priya owns the pricing page and the launch is on Friday', extraction())
  assert.deepEqual(search(db, 'what is the', 5), [])
  assert.deepEqual(search(db, 'क्या है यह', 5), [])
  assert.equal(search(db, 'what is the pricing', 5)[0].clip, 'a')
})

test('search and graph can be limited to chosen contexts, and nodes report their contexts', () => {
  const db = openDb(':memory:')
  insertExtraction(db, 'w', 'Priya owns the launch pricing', extraction({ context: 'company' }))
  insertExtraction(db, 'p', 'Birthday cake for mom pricing no', extraction({
    context: 'personal', summary: 'Mom birthday cake', entities: [{ name: 'Mom', type: 'person' }], edges: [], action_items: [],
  }))
  assert.deepEqual(search(db, 'pricing', 5, ['company']).map((h) => h.clip), ['w'])
  assert.deepEqual(search(db, 'pricing', 5, ['company', 'personal']).map((h) => h.clip).sort(), ['p', 'w'])
  assert.equal(search(db, 'pricing', 5).length, 2, 'no filter means everything')
  const g = graphData(db)
  assert.deepEqual(g.nodes.find((n) => n.name === 'Mom')?.contexts, ['personal'])
  assert.deepEqual(g.nodes.find((n) => n.name === 'Priya')?.contexts, ['company'])
  assert.equal(g.edges[0].context, 'company')
  assert.deepEqual(graphData(db, ['personal']).nodes.map((n) => n.name), ['Mom'])
  assert.equal(graphData(db, ['personal']).edges.length, 0)
})

test('graphData returns nodes with mention counts and edges for the graph view', () => {
  const db = openDb(':memory:')
  insertExtraction(db, 'a', 'x', extraction())
  const g = graphData(db)
  assert.deepEqual(g.nodes.map((n) => n.name).sort(), ['Launch', 'Priya'])
  assert.equal(g.edges.length, 1)
  assert.equal(g.edges[0].relation, 'owns')
})

test('financial, medical and explicit notes are never stored, even when the model says keep', () => {
  const db = openDb(':memory:')
  for (const sensitivity of ['financial', 'medical', 'explicit']) {
    const id = insertExtraction(db, `s-${sensitivity}`, 'text that must not be stored', extraction({ sensitivity }))
    assert.equal(id, null)
  }
  assert.equal(count(db, 'segments'), 0)
  assert.equal(count(db, 'entities'), 0)
  const rows = db.prepare('SELECT reason FROM discarded').all() as { reason: string }[]
  assert.equal(rows.length, 3)
  assert.ok(rows.every((r) => /sensitive/.test(r.reason)))
  assert.ok(!JSON.stringify(rows).includes('must not be stored'))
})

test('personal-sensitivity notes are still kept, in the personal space', () => {
  const db = openDb(':memory:')
  assert.ok(insertExtraction(db, 'p', 'weekend trip', extraction({ sensitivity: 'personal', context: 'personal' })))
})

test('purgeBlocked removes already-stored sensitive notes with their facts and orphan entities', () => {
  const db = openDb(':memory:')
  const id = insertExtraction(db, 'a', 'Priya owns the launch pricing', extraction())!
  insertExtraction(db, 'b', 'Rahul reviews templates', extraction({ summary: 'Rahul', entities: [{ name: 'Rahul', type: 'person' }], edges: [], action_items: [] }))
  db.prepare("UPDATE segments SET sensitivity = 'medical' WHERE id = ?").run(id)
  assert.equal(purgeBlocked(db), 1)
  assert.equal(count(db, 'segments'), 1)
  assert.equal(count(db, 'edges'), 0)
  assert.equal(count(db, 'actions'), 0)
  assert.deepEqual((db.prepare('SELECT name FROM entities').all() as { name: string }[]).map((r) => r.name), ['Rahul'])
  assert.equal(search(db, 'pricing', 5).length, 0)
  assert.equal(count(db, 'discarded'), 1)
})

test('sensitivity is deny by default: odd casing, spaces, unknown or empty values are never stored', () => {
  const db = openDb(':memory:')
  for (const sensitivity of ['Financial', ' medical ', 'EXPLICIT', 'unknown', '', 'health', 'financial info']) {
    assert.equal(insertExtraction(db, `s-${sensitivity}`, 'text that must not be stored', extraction({ sensitivity })), null, `"${sensitivity}" must not be stored`)
  }
  assert.equal((db.prepare('SELECT count(*) AS n FROM segments').get() as { n: number }).n, 0)
  assert.ok(insertExtraction(db, 'ok', 'fine', extraction({ sensitivity: ' None ' })))
})

test('purgeBlocked also removes stored notes whose sensitivity is not an allowed value', () => {
  const db = openDb(':memory:')
  const id = insertExtraction(db, 'a', 'text', extraction()) as number
  db.prepare("UPDATE segments SET sensitivity = 'Medical ' WHERE id = ?").run(id)
  assert.equal(purgeBlocked(db), 1)
})

test('search matches word stems: travelled finds a note about travel', () => {
  const db = openDb(':memory:')
  insertExtraction(db, 'a', 'We love to travel in the hills.', { keep: true, reason: '', sensitivity: 'none', context: 'personal', summary: 'Loves travel', entities: [], edges: [], action_items: [] })
  assert.equal(search(db, 'where have I travelled', 5).length, 1)
})

test('search words stored with a note are searchable, so a question can match without sharing a word', () => {
  const db = openDb(':memory:')
  insertExtraction(db, 'a', 'Weekend at Zermatt with friends.', { keep: true, reason: '', sensitivity: 'none', context: 'personal', summary: 'Weekend at Zermatt', entities: [], edges: [], action_items: [], keywords: ['trip', 'vacation', 'yatra'] })
  assert.equal(search(db, 'which trips did I take', 5)[0]?.clip, 'a')
})

test('an older database is upgraded in place and keeps its notes searchable', async () => {
  const { mkdtempSync } = await import('node:fs')
  const { join } = await import('node:path')
  const { tmpdir } = await import('node:os')
  const { DatabaseSync } = await import('node:sqlite')
  const path = join(mkdtempSync(join(tmpdir(), 'pk-')), 'old.db')
  const old = new DatabaseSync(path)
  old.exec(`CREATE TABLE segments (id INTEGER PRIMARY KEY, clip TEXT UNIQUE NOT NULL, text TEXT NOT NULL, summary TEXT NOT NULL,
    context TEXT NOT NULL, sensitivity TEXT NOT NULL, created_at TEXT NOT NULL DEFAULT (datetime('now')));
    CREATE VIRTUAL TABLE segments_fts USING fts5(text, summary);
    CREATE TRIGGER segments_ai AFTER INSERT ON segments BEGIN INSERT INTO segments_fts(rowid, text, summary) VALUES (new.id, new.text, new.summary); END;
    CREATE TRIGGER segments_ad AFTER DELETE ON segments BEGIN DELETE FROM segments_fts WHERE rowid = old.id; END;
    INSERT INTO segments(clip, text, summary, context, sensitivity) VALUES ('x', 'We travel a lot.', 'Travel', 'personal', 'none');`)
  old.close()
  const db = openDb(path)
  assert.equal(search(db, 'travelled', 5)[0]?.clip, 'x')
  insertExtraction(db, 'y', 'Gym at seven.', { keep: true, reason: '', sensitivity: 'none', context: 'personal', summary: 'Gym', entities: [], edges: [], action_items: [], keywords: ['workout'] })
  assert.equal(search(db, 'workout', 5)[0]?.clip, 'y')
})

test('forgetting a note that replaced another brings the older one back instead of hiding it for good', () => {
  const db = openDb(':memory:')
  const base = { keep: true, reason: '', sensitivity: 'none', context: 'company' as const, entities: [], edges: [], action_items: [] }
  const old = insertExtraction(db, 'old', 'Orbit launches Friday.', { ...base, summary: 'Orbit Friday' })!
  const now = insertExtraction(db, 'new', 'Orbit launches Monday.', { ...base, summary: 'Orbit Monday' })!
  supersede(db, now, [old])
  deleteSegment(db, now)
  assert.deepEqual(search(db, 'Orbit', 5).map((h) => h.clip), ['old'])
})

test('every note can be listed for review, including replaced ones and ones with no graph nodes', () => {
  const db = openDb(':memory:')
  const base = { keep: true, reason: '', sensitivity: 'none', edges: [], action_items: [] }
  const a = insertExtraction(db, 'a', 'Gym at seven.', { ...base, context: 'personal', summary: 'Gym at seven', entities: [] })!
  const b = insertExtraction(db, 'b', 'Gym at six.', { ...base, context: 'personal', summary: 'Gym at six', entities: [] })!
  insertExtraction(db, 'c', 'Atlas ships.', { ...base, context: 'company', summary: 'Atlas ships', entities: [{ name: 'Atlas', type: 'project' }] })
  supersede(db, b, [a])
  const rows = listNotes(db, ['personal'], 10)
  assert.deepEqual(rows.map((r) => [r.summary, r.replaced]), [['Gym at six', false], ['Gym at seven', true]])
  assert.ok(rows.every((r) => typeof r.id === 'number' && typeof r.createdAt === 'string'))
})

test('action items become to-dos with a status, from current notes in the asked spaces only', () => {
  const db = openDb(':memory:')
  const base = { keep: true, reason: '', sensitivity: 'none', entities: [], edges: [] }
  insertExtraction(db, 'w', 'Ravi will send the Atlas deck.', { ...base, context: 'company', summary: 'Atlas deck', action_items: [{ text: 'Send the Atlas deck', owner: 'Ravi' }] })
  const old = insertExtraction(db, 'o', 'Book the Hills hotel.', { ...base, context: 'personal', summary: 'Hills hotel', action_items: [{ text: 'Book the hotel' }] })!
  const now = insertExtraction(db, 'n', 'Hotel booked; buy train tickets.', { ...base, context: 'personal', summary: 'Hills train', action_items: [{ text: 'Buy train tickets' }] })!
  supersede(db, now, [old])
  assert.deepEqual(listTodos(db, ['company']).map((t) => [t.text, t.owner, t.status]), [['Send the Atlas deck', 'Ravi', 'open']])
  const personal = listTodos(db, ['personal'])
  assert.deepEqual(personal.map((t) => t.text), ['Buy train tickets'], 'to-dos of replaced notes are gone')
  setTodoStatus(db, personal[0].id, 'done')
  assert.equal(listTodos(db, ['personal'])[0].status, 'done')
  assert.throws(() => setTodoStatus(db, personal[0].id, 'whatever' as never))
})

test('a replaced note can be restored', () => {
  const db = openDb(':memory:')
  const base = { keep: true, reason: '', sensitivity: 'none', context: 'company' as const, entities: [], edges: [], action_items: [] }
  const a = insertExtraction(db, 'a', 'Orbit launches Friday.', { ...base, summary: 'Orbit Friday' })!
  const b = insertExtraction(db, 'b', 'Orbit launches Friday!', { ...base, summary: 'Orbit Friday again' })!
  supersede(db, b, [a])
  restoreNote(db, a)
  assert.deepEqual(search(db, 'Orbit', 5).map((h) => h.clip).sort(), ['a', 'b'])
})

test('a note keeps when it happened, separately from when it was saved', () => {
  const db = openDb(':memory:')
  insertExtraction(db, 'trip', 'Went to Zermatt in June 2024.', { keep: true, reason: '', sensitivity: 'none', context: 'personal', summary: 'Zermatt trip', entities: [], edges: [], action_items: [], happened: '2024-06' })
  assert.equal(search(db, 'Zermatt', 5)[0].happened, '2024-06')
  assert.equal(listNotes(db, ['personal'], 5)[0].happened, '2024-06')
})
