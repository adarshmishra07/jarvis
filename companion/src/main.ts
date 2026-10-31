import { existsSync, mkdirSync, readdirSync, readFileSync, rmSync, writeFileSync } from 'node:fs'
import { homedir } from 'node:os'
import { dirname, join } from 'node:path'
import { openDb } from './db.ts'
import { startServer } from './server.ts'
import { consolidate, isNightlyDue, lastRunAt } from './consolidate.ts'
import { ledgered } from './ledger.ts'
import { Browser } from './browser.ts'
import { SkillStore } from './skills.ts'
import { handsClient } from './computer.ts'
import { EMBED_MODEL, embedMissing, loadEmbedder } from './embed.ts'
import { execFileSync } from 'node:child_process'

const APP_ID = 'dev.agentpikachu.app'
const container = join(homedir(), 'Library', 'Containers', APP_ID, 'Data')
const socketPath = process.env.PIKACHU_SOCKET ?? join(container, 'companion.sock')
const dbPath = process.env.PIKACHU_DB ?? join(homedir(), 'Library', 'Application Support', 'agent-pikachu', 'memory.db')
const ledgerPath = process.env.PIKACHU_LEDGER ?? join(homedir(), 'Library', 'Application Support', 'agent-pikachu', 'ledger.jsonl')

// Missing keys do not stop the companion: the app shows what is missing and the user adds it in Settings > Setup.
const anthropicKey = process.env.ANTHROPIC_API_KEY ?? ''
const typesafeKey = process.env.TYPESAFE_API_KEY ?? ''

mkdirSync(dirname(dbPath), { recursive: true })
// The app creates its container on first launch; wait for it rather than creating it ourselves.
for (let i = 0; i < 120 && !existsSync(dirname(socketPath)); i++) await new Promise((r) => setTimeout(r, 500))

const glossaryPath = process.env.PIKACHU_GLOSSARY
const glossary = glossaryPath && existsSync(glossaryPath) ? (JSON.parse(readFileSync(glossaryPath, 'utf8')) as string[]) : []
// Hard spelling fixes, e.g. {"zentra": "Zentro"}: applied to questions, new notes and notes already stored.
const spellingsPath = process.env.PIKACHU_SPELLINGS
const aliasesPath = process.env.PIKACHU_ALIASES
const aliases = aliasesPath && existsSync(aliasesPath) ? (JSON.parse(readFileSync(aliasesPath, 'utf8')) as Record<string, string>) : {}
const spellings = spellingsPath && existsSync(spellingsPath) ? (JSON.parse(readFileSync(spellingsPath, 'utf8')) as Record<string, string>) : {}

// MCP servers the user added: names and addresses in mcp.json, header values in the Keychain.
const mcpPath = join(dirname(dbPath), 'mcp.json')
const keychain = (args: string[]): string => execFileSync('security', args, { encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'] }).trim()
const secrets = {
  get: (account: string): string | undefined => { try { return keychain(['find-generic-password', '-s', 'dev.agentpikachu', '-a', account, '-w']) } catch { return undefined } },
  set: (account: string, value: string): void => { keychain(['add-generic-password', '-U', '-s', 'dev.agentpikachu', '-a', account, '-w', value]) },
  remove: (account: string): void => { try { keychain(['delete-generic-password', '-s', 'dev.agentpikachu', '-a', account]) } catch { /* already gone */ } },
}
const savedMcp = existsSync(mcpPath) ? (JSON.parse(readFileSync(mcpPath, 'utf8')) as { name: string; url: string; headerName?: string }[]) : []
const mcpServers = savedMcp.map((m) => {
  let value = ''
  try { value = m.headerName ? keychain(['find-generic-password', '-s', 'dev.agentpikachu', '-a', `mcp:${m.name}`, '-w']) : '' } catch { /* missing secret: connect without it */ }
  return { name: m.name, url: m.url, headers: m.headerName && value ? { [m.headerName]: value } : {} }
})
const saveMcp = (list: object[]): void => writeFileSync(mcpPath, JSON.stringify(list, null, 2), { mode: 0o600 })

const db = openDb(dbPath)
// Meaning search, with the model install-launchagent.sh puts next to the memory. Without it, notes are found by words.
const embedDir = join(dirname(dbPath), 'models', EMBED_MODEL)
const embedder = existsSync(embedDir)
  ? await loadEmbedder(embedDir).catch((error) => { console.error(`meaning search off: ${error instanceof Error ? error.message : 'unknown'}`); return undefined })
  : undefined
// Jarvis's own browser: a separate profile next to the memory, opened only when a task needs it.
const handsApp = join(dirname(dbPath), 'Jarvis Hands.app') // computer use, installed by scripts/install-hands.sh
const browser = new Browser(join(dirname(dbPath), 'browser'))
for (const signal of ['SIGTERM', 'SIGINT'] as const) process.on(signal, () => { void browser.close().finally(() => process.exit(0)) })
await startServer({
  socketPath, db, ledgerPath,
  deps: { appHome: join(homedir(), 'Library', 'Application Support', 'agent-pikachu'), updateLog: join(homedir(), 'Library', 'Logs', 'agent-pikachu', 'update.log'), fetch, anthropicKey, typesafeKey, embedder, tinyfishKey: process.env.TINYFISH_API_KEY || undefined, firecrawlKey: process.env.FIRECRAWL_API_KEY || undefined, glossary, spellings, aliases, browser, skills: new SkillStore(join(dirname(dbPath), 'skills')), hands: existsSync(handsApp) ? handsClient(join(dirname(dbPath), 'hands.sock'), handsApp) : undefined, composioKey: process.env.COMPOSIO_API_KEY || undefined, mcpServers, secrets, saveMcp, restart: () => { void browser.close().finally(() => process.exit(0)) },
    onLearned: (learned) => {
      if (spellingsPath) writeFileSync(spellingsPath, JSON.stringify(learned.spellings, null, 2))
      if (glossaryPath) writeFileSync(glossaryPath, JSON.stringify(learned.glossary, null, 2))
    } },
})
console.log('companion listening')

// New and changed notes get their meaning vector in the background; a note is found by its words until then.
const EMBED_CHECK_MS = 30 * 1000
let embedding = false
async function embedNew(): Promise<void> {
  if (!embedder || embedding) return
  embedding = true
  try {
    let done = 0
    for (let n; (n = await embedMissing(db, embedder)); done += n) await new Promise((r) => setTimeout(r, 50)) // small batches, the helper stays responsive
    if (done) console.log(`meaning search: ${done} notes ready`)
  } catch (error) {
    console.error(`meaning search: ${error instanceof Error ? error.message : 'unknown'}`)
  } finally {
    embedding = false
  }
}
void embedNew()
setInterval(() => void embedNew(), EMBED_CHECK_MS)

// Nightly memory clean-up. A backup comes first (the last 7 are kept); nothing runs while cloud processing is paused.
const backups = join(dirname(dbPath), 'backups')
const NIGHTLY_CHECK_MS = 15 * 60 * 1000
const KEEP_BACKUPS = 7
setInterval(async () => {
  const paused = (db.prepare("SELECT value FROM settings WHERE key = 'pauseCloud'").get() as { value: string } | undefined)?.value === 'true'
  if (paused || !anthropicKey || !isNightlyDue(new Date(), lastRunAt(db))) return
  try {
    mkdirSync(backups, { recursive: true })
    db.exec(`VACUUM INTO '${join(backups, `memory-${new Date().toISOString().slice(0, 10)}.db`).replaceAll("'", "''")}'`)
    for (const old of readdirSync(backups).filter((f) => f.endsWith('.db')).sort().slice(0, -KEEP_BACKUPS)) rmSync(join(backups, old))
    const r = await consolidate(db, { fetch: ledgered(fetch, ledgerPath), apiKey: anthropicKey }, { now: new Date() })
    console.log(`nightly clean-up: checked ${r.checked}, notes replaced ${r.notesMerged}, entities merged ${r.entitiesMerged}`)
  } catch (error) {
    console.error(`nightly clean-up failed: ${error instanceof Error ? error.message : 'unknown'}`)
  }
}, NIGHTLY_CHECK_MS)
