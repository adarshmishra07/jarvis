import { spawn } from 'node:child_process'
import { closeSync, existsSync, openSync, readFileSync } from 'node:fs'
import { join } from 'node:path'

// The in-app Update button. New versions are built and staged in Application Support (scripts/stage-update.sh);
// installing one runs the staged apply script, detached so it survives the companion restarting at its end.

export interface UpdateStatus { installed: string; installedAt: string; ready: boolean; version?: string; builtAt?: string; notes: string[] }

const lines = (path: string): string[] => (existsSync(path) ? readFileSync(path, 'utf8').split('\n').map((l) => l.trim()).filter(Boolean) : [])

export function updateStatus(home: string): UpdateStatus {
  const [installed = 'unknown', installedAt = ''] = lines(join(home, 'installed-version'))
  const [version, builtAt] = lines(join(home, 'staged', 'version'))
  const ready = Boolean(version) && version !== installed && existsSync(join(home, 'staged', 'apply.sh'))
  return { installed, installedAt, ready, ...(ready ? { version, builtAt } : {}), notes: ready ? lines(join(home, 'staged', 'notes')).slice(0, 30) : [] }
}

/** Starts the install in its own session, logging to the update log. Returns false when nothing is staged. */
export function applyUpdate(home: string, logPath: string): boolean {
  if (!updateStatus(home).ready) return false
  const log = openSync(logPath, 'a')
  spawn('/bin/bash', [join(home, 'staged', 'apply.sh')], { detached: true, stdio: ['ignore', log, log] }).unref()
  closeSync(log) // the script has its own copy
  return true
}
