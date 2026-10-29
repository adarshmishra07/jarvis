import { openDb } from './db.ts'
import { whenHappened } from './llm.ts'

// One-time: works out when each existing note's event happened (imports included). Notes saved from now on get it at once.
// Usage: node --experimental-strip-types src/backfill-happened.ts <memory.db>   (ANTHROPIC_API_KEY in the environment)
// Prints counts only. Never prints note text.
const db = openDb(process.argv[2])
db.exec('PRAGMA busy_timeout = 5000') // the companion may be writing too
const apiKey = process.env.ANTHROPIC_API_KEY
if (!apiKey) throw new Error('ANTHROPIC_API_KEY is empty')
const rows = db.prepare('SELECT id, clip, summary, text, created_at FROM segments WHERE happened_checked = 0').all() as { id: number; clip: string; summary: string; text: string; created_at: string }[]
const stats = { notes: rows.length, dated: 0, noDateInText: 0, failed: 0 }
const queue = [...rows]
await Promise.all(Array.from({ length: 4 }, async () => {
  for (let r = queue.shift(); r; r = queue.shift()) {
    try {
      const happened = await whenHappened(`${r.summary}\n${r.text}`, r.created_at, r.clip.startsWith('import:'), { fetch, apiKey })
      db.prepare('UPDATE segments SET happened = ?, happened_checked = 1 WHERE id = ?').run(happened, r.id)
      happened ? stats.dated++ : stats.noDateInText++
    } catch { stats.failed++ }
  }
}))
console.log(JSON.stringify(stats))
