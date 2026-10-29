import net from 'node:net'
import { readFileSync } from 'node:fs'
import { basename, join } from 'node:path'
import { homedir } from 'node:os'
import { DatabaseSync } from 'node:sqlite'
import { chunkMarkdown } from './chunk.ts'
import { encode } from './protocol.ts'

// Feeds markdown files to the running companion, oldest first, so newer facts replace older ones.
// Usage: node --experimental-strip-types src/import.ts <oldest.md> ... <newest.md>
// Set PIKACHU_DB to skip chunks already stored or discarded (for re-running after failures).
// Prints counts only. Never prints note text.
const CHUNK_CHARS = 2000
const WORKERS = 3
const socketPath = process.env.PIKACHU_SOCKET ?? join(homedir(), 'Library', 'Containers', 'dev.agentpikachu.app', 'Data', 'companion.sock')

function ingest(text: string, clipId: string): Promise<{ type: string; kept?: boolean; context?: string; replaced?: number; code?: string }> {
  return new Promise((resolve, reject) => {
    let buf = ''
    const c = net.createConnection(socketPath, () => c.write(encode({ id: clipId, type: 'ingest', text, clipId })))
    c.setEncoding('utf8')
    c.on('data', (d: string) => { buf += d; if (buf.includes('\n')) { c.end(); resolve(JSON.parse(buf.split('\n')[0])) } })
    c.on('error', reject)
  })
}

const done = new Set<string>()
if (process.env.PIKACHU_DB) {
  const db = new DatabaseSync(process.env.PIKACHU_DB, { readOnly: true })
  for (const r of db.prepare('SELECT clip FROM segments UNION SELECT clip FROM discarded').all() as { clip: string }[]) done.add(r.clip)
  db.close()
}

for (const file of process.argv.slice(2)) {
  const name = basename(file)
  const queue = chunkMarkdown(readFileSync(file, 'utf8'), name, CHUNK_CHARS).map((c, i) => ({ text: c.text, clipId: `import:${name}#${i + 1}`, tries: 0 }))
    .filter((c) => !done.has(c.clipId))
  const stats = { chunks: queue.length, kept: 0, discarded: 0, failed: 0, replaced: 0, spaces: {} as Record<string, number>, errors: {} as Record<string, number> }
  await Promise.all(Array.from({ length: WORKERS }, async () => {
    for (let item = queue.shift(); item; item = queue.shift()) {
      const r = await ingest(item.text, item.clipId).catch(() => ({ type: 'error' as const, message: 'socket' }))
      if (r.type !== 'result') {
        if (++item.tries < 3) { queue.push(item); continue } // retried at the end of the queue
        // Only the kind of error: some messages (JSON parse errors) can quote text.
        const msg = String((r as { message?: string }).message ?? '')
        const why = msg.match(/^anthropic request failed: \d+$/)?.[0] ?? (/UNIQUE/.test(msg) ? 'duplicate' : /wrong shape|bad item|no JSON object/.test(msg) ? msg.match(/wrong shape|bad item|no JSON object/)![0] : /JSON|extraction/.test(msg) ? 'json syntax' : msg === 'socket' ? 'socket' : 'other')
        stats.errors[why] = (stats.errors[why] ?? 0) + 1
        stats.failed++
        continue
      }
      if (!r.kept) { stats.discarded++; continue }
      stats.kept++
      stats.replaced += r.replaced ?? 0
      if (r.context) stats.spaces[r.context] = (stats.spaces[r.context] ?? 0) + 1
    }
  }))
  console.log(JSON.stringify({ file: name, ...stats }))
}
