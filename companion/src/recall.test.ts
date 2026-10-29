import { test } from 'node:test'
import assert from 'node:assert/strict'
import { dateWindow, excerpt, mentions } from './recall.ts'
import { openDb, insertExtraction, inWindow, type Extraction } from './db.ts'

const now = new Date('2026-10-29T12:00:00') // Thursday

test('questions about a time get the dates they mean', () => {
  assert.deepEqual(dateWindow('what did I do last week', now), { from: '2026-10-19', to: '2026-10-25' })
  assert.deepEqual(dateWindow('what happened this week', now), { from: '2026-10-26', to: '2026-10-29' })
  assert.deepEqual(dateWindow('pichle mahine kya hua', now), { from: '2026-09-01', to: '2026-09-30' })
  assert.deepEqual(dateWindow('पिछले साल क्या किया', now), { from: '2025-01-01', to: '2025-12-31' })
  assert.deepEqual(dateWindow('what was I doing in June 2024', now), { from: '2024-06-01', to: '2024-06-30' })
  assert.deepEqual(dateWindow('what did I do in December', now), { from: '2025-12-01', to: '2025-12-31' }, 'the latest December so far')
  assert.deepEqual(dateWindow('what happened in 2023', now), { from: '2023-01-01', to: '2023-12-31' })
  assert.deepEqual(dateWindow('anything in the last 10 days', now), { from: '2026-10-19', to: '2026-10-29' })
})

test('questions with no time in them get no dates', () => {
  for (const q of ['who leads Atlas', 'may I ask who owns billing', 'kal ka plan kya hai', 'the 2023 roadmap doc']) assert.equal(dateWindow(q, now), null, q)
})

test('a long note shows the part that matches the question', () => {
  const text = `${'filler words about the agenda. '.repeat(60)}Decision: Leo will own the incident runbook. ${'more filler. '.repeat(20)}`
  const shown = excerpt(text, ['Who owns the incident runbook?'], 300)
  assert.ok(shown.includes('Leo will own the incident runbook'))
  assert.ok(shown.length <= 302 && shown.startsWith('…'))
  assert.equal(excerpt('short note', ['anything'], 300), 'short note')
})

test('names count only as whole words', () => {
  assert.equal(mentions('What did Asha said?', 'AI'), false)
  assert.equal(mentions('Is Ravi going?', 'Go'), false)
  assert.equal(mentions('how is the AI team doing', 'AI'), true)
  assert.equal(mentions('Who owns the Orbit API?', 'orbit api'), true)
  assert.equal(mentions('anything', 'C++'), false)
})

test('notes in a date window: when they happened, else when written, never the import day', () => {
  const db = openDb(':memory:')
  const ex = (happened = ''): Extraction => ({ keep: true, reason: '', sensitivity: 'none', context: 'company', summary: 's', entities: [], edges: [], action_items: [], happened })
  insertExtraction(db, 'june', 'trip', ex('2024-06'))
  insertExtraction(db, 'written', 'standup', ex())
  insertExtraction(db, 'import:a.md#1', 'old fact', ex())
  db.exec("UPDATE segments SET created_at = '2026-10-27 09:00:00'")
  assert.deepEqual(inWindow(db, '2024-06-10', '2024-06-12', 5).map((h) => h.clip), ['june'], 'a month counts for any day in it')
  assert.deepEqual(inWindow(db, '2026-10-26', '2026-10-29', 5).map((h) => h.clip), ['written'], 'an imported note is not about its import day')
})
