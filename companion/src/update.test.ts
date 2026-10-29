import { test } from 'node:test'
import assert from 'node:assert/strict'
import { mkdirSync, mkdtempSync, writeFileSync, existsSync, readFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { applyUpdate, updateStatus } from './update.ts'

function home(installed: string, staged?: string) {
  const dir = mkdtempSync(join(tmpdir(), 'upd-'))
  writeFileSync(join(dir, 'installed-version'), `${installed}\n2026-10-22 17:00\n`)
  if (staged) {
    mkdirSync(join(dir, 'staged'))
    writeFileSync(join(dir, 'staged', 'version'), `${staged}\n2026-10-22 18:00\n`)
    writeFileSync(join(dir, 'staged', 'notes'), 'fix: calls stay audible\nfeat: update button\n')
    writeFileSync(join(dir, 'staged', 'apply.sh'), `echo ran > "${join(dir, 'applied')}"\n`)
  }
  return dir
}

test('a staged newer version is ready, with what changed', () => {
  const s = updateStatus(home('abc1234', 'def5678'))
  assert.deepEqual(s, { installed: 'abc1234', installedAt: '2026-10-22 17:00', ready: true, version: 'def5678', builtAt: '2026-10-22 18:00', notes: ['fix: calls stay audible', 'feat: update button'] })
})

test('nothing staged, or the staged version is the installed one: no update', () => {
  assert.equal(updateStatus(home('abc1234')).ready, false)
  assert.equal(updateStatus(home('abc1234', 'abc1234')).ready, false)
})

test('applying runs the staged script on its own, and does nothing when no update is ready', async () => {
  const dir = home('abc1234', 'def5678')
  assert.equal(applyUpdate(dir, join(dir, 'log')), true)
  for (let i = 0; i < 50 && !existsSync(join(dir, 'applied')); i++) await new Promise((r) => setTimeout(r, 20))
  assert.equal(readFileSync(join(dir, 'applied'), 'utf8').trim(), 'ran')
  assert.equal(applyUpdate(home('abc1234'), join(dir, 'log')), false)
})
