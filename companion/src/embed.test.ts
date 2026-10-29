import { test } from 'node:test'
import assert from 'node:assert/strict'
import { openDb, insertExtraction, similar, EMBED_MODEL, type Extraction } from './db.ts'
import { embedMissing, type Embedder } from './embed.ts'
import { recall } from './ask.ts'

const ex = (summary: string): Extraction => ({ keep: true, reason: '', sensitivity: 'none', context: 'company', summary, entities: [], edges: [], action_items: [] })
const unit = (...xs: number[]): Float32Array => { const n = Math.hypot(...xs); return Float32Array.from(xs.map((x) => x / n)) }
// A stand-in model: gym and workout words point one way, cars another.
const fake: Embedder = { embed: async (texts) => texts.map((t) => /gym|work ?out|exercise/i.test(t) ? unit(1, 0.1, 0) : /car|gaadi/i.test(t) ? unit(0, 1, 0.1) : unit(0.1, 0, 1)) }

test('every note gets a vector once, and a changed note gets a new one', async () => {
  const db = openDb(':memory:')
  insertExtraction(db, 'gym', 'Going to the gym three times a week.', ex('Gym routine'))
  insertExtraction(db, 'car', 'Car service due next month.', ex('Car service'))
  assert.equal(await embedMissing(db, fake), 2)
  assert.equal(await embedMissing(db, fake), 0, 'nothing left to do')
  db.exec("UPDATE segments SET embedded_with = '' WHERE clip = 'car'") // what a respelling does
  assert.equal(await embedMissing(db, fake), 1)
})

test('a question finds the note that means the same, and nothing below the floor', async () => {
  const db = openDb(':memory:')
  insertExtraction(db, 'gym', 'Going to the gym three times a week.', ex('Gym routine'))
  insertExtraction(db, 'car', 'Car service due next month.', ex('Car service'))
  await embedMissing(db, fake)
  const [q] = await fake.embed(['How often do I work out?'], 'query')
  assert.deepEqual(similar(db, q, EMBED_MODEL, 5, 0.5).map((h) => h.clip), ['gym'])
  assert.deepEqual(recall(db, 'How often do I work out?', [], ['company'], new Date(), q).map((h) => h.clip), ['gym'], 'no word in common, still found')
  assert.deepEqual(similar(db, q, 'another-model', 5, 0.5), [], 'vectors from another model are never compared')
  const [hi] = await fake.embed(['hi there'], 'query')
  assert.deepEqual(recall(db, 'hi there', [], ['company'], new Date(), hi), [], 'small talk finds no notes')
})
