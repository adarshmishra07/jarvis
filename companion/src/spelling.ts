import type { DatabaseSync } from 'node:sqlite'
import { reindex } from './db.ts'

/** Wrong spelling (lowercase) to the right one, e.g. { "zentra": "Zentro" }. Kept in a local file, not in code. */
export type Spellings = Record<string, string>

const escape = (s: string): string => s.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')

/** Replaces whole-word misspellings, in any case, with the right spelling. */
export function fixSpelling(text: string, map: Spellings): string {
  let out = text
  for (const [wrong, right] of Object.entries(map)) {
    // The right form is matched first and left alone, so "Zentro" to "Zentro AI" never becomes "Zentro AI AI".
    out = out.replace(new RegExp(`(?<![\\p{L}\\p{N}])(?:${escape(right)}|${escape(wrong)})(?![\\p{L}\\p{N}])`, 'giu'),
      (found) => (found.toLowerCase() === right.toLowerCase() ? found : right))
  }
  return out
}

/** Fixes misspellings already stored: note text, summaries, search index and entity names. Returns notes changed. */
export function respellMemory(db: DatabaseSync, map: Spellings): number {
  if (!Object.keys(map).length) return 0
  let changed = 0
  const rows = db.prepare('SELECT id, text, summary FROM segments').all() as { id: number; text: string; summary: string }[]
  for (const r of rows) {
    const text = fixSpelling(r.text, map)
    const summary = fixSpelling(r.summary, map)
    if (text === r.text && summary === r.summary) continue
    db.prepare('INSERT INTO respell_log(segment_id, old_text, old_summary) VALUES (?, ?, ?)').run(r.id, r.text, r.summary) // for undo
    db.prepare('UPDATE segments SET text = ?, summary = ? WHERE id = ?').run(text, summary, r.id)
    reindex(db, r.id)
    changed++
  }
  const entities = db.prepare('SELECT id, name FROM entities').all() as { id: number; name: string }[]
  for (const e of entities) {
    const name = fixSpelling(e.name, map)
    if (name !== e.name) renameEntity(db, e.id, name)
  }
  return changed
}

/** Renames a node; when one with that name already exists, moves every mention and link onto it and drops this one. */
function renameEntity(db: DatabaseSync, id: number, name: string): void {
  const key = name.trim().toLowerCase()
  const target = db.prepare('SELECT id FROM entities WHERE key = ? AND id != ?').get(key, id) as { id: number } | undefined
  if (!target) { db.prepare('UPDATE entities SET name = ?, key = ? WHERE id = ?').run(name.trim(), key, id); return }
  db.prepare('INSERT OR IGNORE INTO mentions(entity_id, segment_id) SELECT ?, segment_id FROM mentions WHERE entity_id = ?').run(target.id, id)
  db.prepare('UPDATE edges SET src = ? WHERE src = ?').run(target.id, id)
  db.prepare('UPDATE edges SET dst = ? WHERE dst = ?').run(target.id, id)
  db.prepare('DELETE FROM entities WHERE id = ?').run(id)
}

/** Whole names that mean the same node, e.g. { "user": "<the user's name>", "me": ... }. Returns how many nodes changed. */
export function mergeAliases(db: DatabaseSync, aliases: Record<string, string>): number {
  let changed = 0
  for (const [alias, name] of Object.entries(aliases)) {
    const e = db.prepare('SELECT id, name FROM entities WHERE key = ?').get(alias.trim().toLowerCase()) as { id: number; name: string } | undefined
    if (!e || e.name === name.trim()) continue
    renameEntity(db, e.id, name)
    changed++
  }
  return changed
}
