import { test } from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { never, personal, moneySite } from './never.ts'

const cases = JSON.parse(readFileSync(new URL('./never.cases.json', import.meta.url), 'utf8'))

test('labels, tool names and commands that delete, spend or send are caught, ordinary ones are not', () => {
  for (const kind of ['delete', 'money', 'send'] as const) for (const t of cases.refused[kind]) assert.equal(never(t), kind, t)
  for (const t of cases.allowed) assert.equal(never(t), undefined, t)
})

test('personal numbers and addresses are caught, everyday text is not', () => {
  for (const t of cases.personal.refused) assert.equal(personal(t), true, t)
  for (const t of cases.personal.allowed) assert.equal(personal(t), false, t)
})

test('payment and bank pages are caught by host and path, not by a search about paying', () => {
  for (const u of cases.sites.refused) assert.equal(moneySite(u), true, u)
  for (const u of cases.sites.allowed) assert.equal(moneySite(u), false, u)
  assert.equal(moneySite('https://www.google.com/search?q=how+to+pay+tax'), false)
})
