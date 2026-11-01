// Privacy check: is the Mac itself keeping Jarvis's data private? Disk encryption, firewall, screen lock, the data
// folder (only you can open it, and not synced to iCloud), and whether Jarvis listens on any network port (it should
// not: the app and the companion talk over a private local socket). Read-only: it changes nothing.
import { execFile } from 'node:child_process'
import { realpathSync, statSync, existsSync } from 'node:fs'
import { homedir } from 'node:os'
import { join } from 'node:path'

export interface Check { name: string; ok: boolean; detail: string }
export type Run = (program: string, args: string[]) => Promise<string>

const RUN_TIMEOUT_MS = 5000
/** Output and errors together (sysadminctl reports on stderr); a program that fails yields what it printed. */
export const runProgram: Run = (program, args) => new Promise((resolve) => {
  execFile(program, args, { timeout: RUN_TIMEOUT_MS, env: { PATH: '/usr/bin:/bin:/usr/sbin:/sbin' } }, (_e, out, err) => resolve(`${out}${err}`))
})

export async function privacyCheck(dataDir: string, pids: number[], run: Run = runProgram, home = homedir()): Promise<Check[]> {
  const [vault, firewall, lock, ports] = await Promise.all([
    run('/usr/bin/fdesetup', ['status']),
    run('/usr/libexec/ApplicationFirewall/socketfilterfw', ['--getglobalstate']),
    run('/usr/sbin/sysadminctl', ['-screenLock', 'status']),
    run('/usr/sbin/lsof', ['-nP', '-iTCP', '-sTCP:LISTEN', '-iUDP', '-a', '-p', pids.join(',')]),
  ])
  const delay = Number(/screenLock delay is (\d+)/.exec(lock)?.[1] ?? NaN)
  let real = dataDir
  try { real = realpathSync(dataDir) } catch { /* not created yet */ }
  const cloud = [join(home, 'Library', 'Mobile Documents'), join(home, 'Library', 'CloudStorage')]
  const synced = cloud.some((c) => real.startsWith(c + '/'))
    || (['Desktop', 'Documents'].some((d) => real.startsWith(join(home, d) + '/')) && existsSync(join(home, 'Library', 'Mobile Documents', 'com~apple~CloudDocs', 'Desktop')))
  const mode = existsSync(real) ? statSync(real).mode & 0o777 : 0o700
  const listening = ports.split('\n').slice(1).filter((l) => l.trim()).map((l) => l.split(/\s+/).slice(-2).join(' '))
  return [
    { name: 'Disk encryption (FileVault)', ok: /FileVault is On/.test(vault), detail: vault.trim() || 'Could not tell.' },
    { name: 'Firewall', ok: /enabled|State = [12]/.test(firewall), detail: /enabled|State = [12]/.test(firewall) ? 'On.' : 'Off: System Settings > Network > Firewall.' },
    { name: 'Screen locks soon after sleep', ok: delay <= 300, detail: Number.isNaN(delay) ? 'Could not tell.' : delay === 0 ? 'Immediately.' : `After ${Math.round(delay / 60)} min.` },
    { name: 'Jarvis data only on this Mac', ok: !synced, detail: synced ? 'The data folder is inside a synced folder (iCloud or another cloud drive).' : 'Not in iCloud or a cloud drive.' },
    { name: 'Jarvis data folder only opens for you', ok: (mode & 0o077) === 0, detail: (mode & 0o077) === 0 ? 'Only your account can open it.' : `Others on this Mac can read it (mode ${mode.toString(8)}).` },
    { name: 'Jarvis listens on no network port', ok: listening.length === 0, detail: listening.length ? `Listening: ${listening.join(', ')}` : 'Only a private socket on this Mac.' },
  ]
}
