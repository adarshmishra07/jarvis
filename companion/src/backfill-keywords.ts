import { openDb, reindex } from './db.ts'
import { searchWords } from './llm.ts'

// One-time: adds search words to notes saved before they existed.
// Usage: node --env-file=.env --experimental-strip-types src/backfill-keywords.ts <memory.db>
// Prints counts only. Never prints note text.
const db = openDb(process.argv[2])
db.exec('PRAGMA busy_timeout = 5000') // the companion may be writing too
const apiKey = process.env.ANTHROPIC_API_KEY
if (!apiKey) throw new Error('ANTHROPIC_API_KEY is empty')
const rows = db.prepare("SELECT id, summary, text FROM segments WHERE keywords = ''").all() as { id: number; summary: string; text: string }[]
const stats = { notes: rows.length, done: 0, failed: 0 }
const queue = [...rows]
await Promise.all(Array.from({ length: 4 }, async () => {
  for (let r = queue.shift(); r; r = queue.shift()) {
    try {
      const words = await searchWords(`${r.summary}\n${r.text.slice(0, 3000)}`, { fetch, apiKey })
      db.prepare('UPDATE segments SET keywords = ? WHERE id = ?').run(words.join(' '), r.id)
      reindex(db, r.id)
      stats.done++
    } catch { stats.failed++ }
  }
}))
console.log(JSON.stringify(stats))
