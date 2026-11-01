import { test } from 'node:test'
import assert from 'node:assert/strict'
import { mkdtempSync, mkdirSync, chmodSync, realpathSync } from 'node:fs'
import { join } from 'node:path'
import { tmpdir } from 'node:os'
import { privacyCheck, type Run } from './privacy.ts'

const fake = (out: Record<string, string>): Run => async (program) => out[program.split('/').pop()!] ?? ''

test('a well set up Mac passes every check', async () => {
  const home = realpathSync(mkdtempSync(join(tmpdir(), 'home-')))
  const data = join(home, 'Library', 'Application Support', 'agent-pikachu'); mkdirSync(data, { recursive: true, mode: 0o700 })
  const checks = await privacyCheck(data, [1], fake({ fdesetup: 'FileVault is On.\n', socketfilterfw: 'Firewall is enabled. (State = 1)', sysadminctl: 'x screenLock delay is 5 seconds', lsof: '' }), home)
  assert.deepEqual(checks.filter((c) => !c.ok), [])
})

test('encryption off, an open port, a readable or synced data folder are each reported', async () => {
  const home = realpathSync(mkdtempSync(join(tmpdir(), 'home-')))
  const data = join(home, 'Library', 'Mobile Documents', 'jarvis'); mkdirSync(data, { recursive: true }); chmodSync(data, 0o755)
  const checks = await privacyCheck(data, [1], fake({ fdesetup: 'FileVault is Off.', socketfilterfw: 'Firewall is disabled. (State = 0)', sysadminctl: 'screenLock delay is 3600 seconds',
    lsof: 'COMMAND PID USER FD TYPE DEVICE SIZE/OFF NODE NAME\nnode 1 me 20u IPv4 0x1 0t0 TCP *:8080 (LISTEN)' }), home)
  assert.deepEqual(checks.filter((c) => !c.ok).map((c) => c.name).length, 6)
  assert.match(checks.at(-1)!.detail, /8080/)
})
