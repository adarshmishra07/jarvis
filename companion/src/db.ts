import { DatabaseSync } from 'node:sqlite'

export type Context = 'company' | 'professional' | 'personal'
export const CONTEXTS: readonly Context[] = ['company', 'professional', 'personal']

/** Notes with these sensitivities are never stored, whatever the model decided. */
export const BLOCKED_SENSITIVITY: readonly string[] = ['financial', 'medical', 'explicit']

/** Deny by default: only these values may be stored. Anything else (unknown, odd casing, a new label) is blocked. */
const ALLOWED_SENSITIVITY: readonly string[] = ['none', 'personal']
const storable = (sensitivity: string): boolean => ALLOWED_SENSITIVITY.includes(sensitivity.trim().toLowerCase())

export interface Extraction {
  keep: boolean
  reason: string
  sensitivity: string
  context: Context
  summary: string
  entities: { name: string; type: string }[]
  edges: { source: string; relation: string; target: string }[]
  action_items: { text: string; owner?: string }[]
  /** Words someone might search with to find this note later: synonyms, related words, Hindi or Hinglish. */
  keywords?: string[]
  /** When it happened (not when it was saved): YYYY, YYYY-MM or YYYY-MM-DD, or empty when unknown. */
  happened?: string
}

export interface SearchHit {
  id: number
  clip: string
  summary: string
  text: string
  rank: number
  /** UTC, as SQLite stores it. */
  createdAt: string
  happened: string
}

export interface GraphData {
  nodes: { id: number; name: string; type: string; mentions: number; contexts: Context[] }[]
  edges: { source: number; target: number; relation: string; segment: number; context: Context }[]
}

const SCHEMA = `
  PRAGMA foreign_keys = ON;
  CREATE TABLE IF NOT EXISTS segments (
    id INTEGER PRIMARY KEY, clip TEXT UNIQUE NOT NULL, text TEXT NOT NULL, summary TEXT NOT NULL,
    context TEXT NOT NULL, sensitivity TEXT NOT NULL, created_at TEXT NOT NULL DEFAULT (datetime('now')));
  CREATE TABLE IF NOT EXISTS entities (id INTEGER PRIMARY KEY, key TEXT UNIQUE NOT NULL, name TEXT NOT NULL, type TEXT NOT NULL);
  CREATE TABLE IF NOT EXISTS mentions (
    entity_id INTEGER NOT NULL REFERENCES entities(id) ON DELETE CASCADE,
    segment_id INTEGER NOT NULL REFERENCES segments(id) ON DELETE CASCADE,
    PRIMARY KEY (entity_id, segment_id));
  CREATE TABLE IF NOT EXISTS edges (
    id INTEGER PRIMARY KEY,
    src INTEGER NOT NULL REFERENCES entities(id) ON DELETE CASCADE, rel TEXT NOT NULL,
    dst INTEGER NOT NULL REFERENCES entities(id) ON DELETE CASCADE,
    segment_id INTEGER NOT NULL REFERENCES segments(id) ON DELETE CASCADE);
  CREATE TABLE IF NOT EXISTS actions (
    id INTEGER PRIMARY KEY, segment_id INTEGER NOT NULL REFERENCES segments(id) ON DELETE CASCADE,
    text TEXT NOT NULL, owner TEXT);
  CREATE TABLE IF NOT EXISTS discarded (clip TEXT PRIMARY KEY, reason TEXT NOT NULL);
  CREATE TABLE IF NOT EXISTS feedback (
    id INTEGER PRIMARY KEY, rating TEXT NOT NULL CHECK (rating IN ('up', 'down')), question TEXT NOT NULL, answer TEXT NOT NULL,
    model TEXT NOT NULL DEFAULT '', at TEXT NOT NULL DEFAULT (datetime('now')));
  CREATE TABLE IF NOT EXISTS memory_ops (id INTEGER PRIMARY KEY, run_at TEXT NOT NULL, op TEXT NOT NULL, target INTEGER NOT NULL, detail TEXT NOT NULL);
  CREATE TABLE IF NOT EXISTS consolidation_runs (
    id INTEGER PRIMARY KEY, at TEXT NOT NULL, last_segment INTEGER NOT NULL, notes_merged INTEGER NOT NULL, entities_merged INTEGER NOT NULL);
  CREATE TABLE IF NOT EXISTS respell_log (
    segment_id INTEGER NOT NULL REFERENCES segments(id) ON DELETE CASCADE,
    old_text TEXT NOT NULL, old_summary TEXT NOT NULL, at TEXT NOT NULL DEFAULT (datetime('now')));
`

export function openDb(path: string): DatabaseSync {
  const db = new DatabaseSync(path)
  db.exec(SCHEMA)
  // Added after the first release: a note replaced by a newer one points at it and drops out of search.
  const columns = db.prepare('PRAGMA table_info(segments)').all() as { name: string }[]
  if (!columns.some((c) => c.name === 'superseded_by')) db.exec('ALTER TABLE segments ADD COLUMN superseded_by INTEGER')
  const actionColumns = db.prepare('PRAGMA table_info(actions)').all() as { name: string }[]
  if (!actionColumns.some((c) => c.name === 'status')) db.exec("ALTER TABLE actions ADD COLUMN status TEXT NOT NULL DEFAULT 'open'")
  if (!columns.some((c) => c.name === 'happened')) db.exec("ALTER TABLE segments ADD COLUMN happened TEXT NOT NULL DEFAULT ''")
  if (!columns.some((c) => c.name === 'happened_checked')) db.exec('ALTER TABLE segments ADD COLUMN happened_checked INTEGER NOT NULL DEFAULT 0')
  if (!columns.some((c) => c.name === 'keywords')) db.exec("ALTER TABLE segments ADD COLUMN keywords TEXT NOT NULL DEFAULT ''")
  // Meaning-search vector, and the model that made it (a different model means it is made again).
  if (!columns.some((c) => c.name === 'embedding')) db.exec("ALTER TABLE segments ADD COLUMN embedding BLOB; ALTER TABLE segments ADD COLUMN embedded_with TEXT NOT NULL DEFAULT ''")
  ensureSearchIndex(db)
  return db
}

/** Full-text index over text, summary and search words, with word stems (travelled finds travel). Rebuilt once when the shape changes. */
function ensureSearchIndex(db: DatabaseSync): void {
  const sql = (db.prepare("SELECT sql FROM sqlite_master WHERE name = 'segments_fts'").get() as { sql: string } | undefined)?.sql ?? ''
  if (sql.includes('keywords') && sql.includes('porter')) return
  db.exec(`
    DROP TRIGGER IF EXISTS segments_ai; DROP TRIGGER IF EXISTS segments_ad; DROP TABLE IF EXISTS segments_fts;
    CREATE VIRTUAL TABLE segments_fts USING fts5(text, summary, keywords, tokenize = 'porter unicode61 remove_diacritics 2');
    CREATE TRIGGER segments_ai AFTER INSERT ON segments BEGIN
      INSERT INTO segments_fts(rowid, text, summary, keywords) VALUES (new.id, new.text, new.summary, new.keywords); END;
    CREATE TRIGGER segments_ad AFTER DELETE ON segments BEGIN DELETE FROM segments_fts WHERE rowid = old.id; END;
    INSERT INTO segments_fts(rowid, text, summary, keywords) SELECT id, text, summary, keywords FROM segments;`)
}

/** Keeps the search index in step after a note's text, summary or search words change. */
export function reindex(db: DatabaseSync, id: number): void {
  db.prepare('DELETE FROM segments_fts WHERE rowid = ?').run(id)
  db.prepare('INSERT INTO segments_fts(rowid, text, summary, keywords) SELECT id, text, summary, keywords FROM segments WHERE id = ?').run(id)
}

function entityId(db: DatabaseSync, name: string, type: string): number {
  const key = name.trim().toLowerCase()
  db.prepare('INSERT OR IGNORE INTO entities(key, name, type) VALUES (?, ?, ?)').run(key, name.trim(), type)
  return (db.prepare('SELECT id FROM entities WHERE key = ?').get(key) as { id: number }).id
}

/** Stores an accepted extraction. Returns the segment id, or null when the segment is discarded (no text kept). */
export function insertExtraction(db: DatabaseSync, clip: string, text: string, ex: Extraction): number | null {
  const blocked = !storable(ex.sensitivity)
  if (!ex.keep || blocked) {
    db.prepare('INSERT OR REPLACE INTO discarded(clip, reason) VALUES (?, ?)').run(clip, blocked ? `sensitive: ${ex.sensitivity}` : ex.reason)
    return null
  }
  const segment = Number(
    db.prepare('INSERT INTO segments(clip, text, summary, context, sensitivity, keywords, happened, happened_checked) VALUES (?, ?, ?, ?, ?, ?, ?, 1)')
      .run(clip, text, ex.summary, ex.context, ex.sensitivity, (ex.keywords ?? []).join(' '), ex.happened ?? '').lastInsertRowid,
  )
  for (const e of ex.entities) {
    db.prepare('INSERT OR IGNORE INTO mentions(entity_id, segment_id) VALUES (?, ?)').run(entityId(db, e.name, e.type), segment)
  }
  for (const edge of ex.edges) {
    const src = entityId(db, edge.source, 'topic')
    const dst = entityId(db, edge.target, 'topic')
    db.prepare('INSERT OR IGNORE INTO mentions(entity_id, segment_id) VALUES (?, ?)').run(src, segment)
    db.prepare('INSERT OR IGNORE INTO mentions(entity_id, segment_id) VALUES (?, ?)').run(dst, segment)
    db.prepare('INSERT INTO edges(src, rel, dst, segment_id) VALUES (?, ?, ?, ?)').run(src, edge.relation, dst, segment)
  }
  for (const a of ex.action_items) {
    db.prepare('INSERT INTO actions(segment_id, text, owner) VALUES (?, ?, ?)').run(segment, a.text, a.owner ?? null)
  }
  return segment
}

/** Deletes a segment, everything derived from it, and entities no other segment mentions. */
export function deleteSegment(db: DatabaseSync, id: number): void {
  db.prepare('UPDATE segments SET superseded_by = NULL WHERE superseded_by = ?').run(id) // what it replaced comes back
  db.prepare('DELETE FROM segments WHERE id = ?').run(id)
  db.exec('DELETE FROM entities WHERE id NOT IN (SELECT entity_id FROM mentions)')
}

// Filler words that would match almost every note. Small English + Hindi list; ponytail: replace with a real
// stopword list or IDF weighting if retrieval quality needs it.
const STOPWORDS = new Set((
  'a an the is are was were be been am do does did to of in on at for from by with and or but if so as it its this that these those ' +
  'what who whom when where why how which i me my we our you your he she they them his her their can could will would should ' +
  'about tell show give any there here has have had not no yes ' +
  'क्या है हैं था थी थे यह वह और का की के को में से पर ने कि भी तो ये वो कौन कब कहां कैसे कुछ'
).split(/\s+/))

/** Removes notes already stored with a blocked sensitivity (and what was derived from them). Returns how many. */
export function purgeBlocked(db: DatabaseSync): number {
  const all = db.prepare('SELECT id, clip, sensitivity FROM segments').all() as { id: number; clip: string; sensitivity: string }[]
  const rows = all.filter((r) => !storable(r.sensitivity))
  for (const r of rows) {
    db.prepare('INSERT OR REPLACE INTO discarded(clip, reason) VALUES (?, ?)').run(r.clip, `sensitive: ${r.sensitivity}`)
    deleteSegment(db, r.id)
  }
  return rows.length
}

export function ftsQuery(query: string): string | null {
  const tokens = query.split(/[^\p{L}\p{N}\p{M}]+/u).filter((t) => t.length > 1 && !STOPWORDS.has(t.toLowerCase()))
  return tokens.length ? tokens.map((t) => `"${t}"`).join(' OR ') : null
}

function contextClause(column: string, contexts?: Context[]): { sql: string; params: Context[] } {
  if (!contexts) return { sql: '', params: [] }
  if (contexts.length === 0) return { sql: ' AND 0', params: [] }
  return { sql: ` AND ${column} IN (${contexts.map(() => '?').join(',')})`, params: contexts }
}

export function search(db: DatabaseSync, query: string, limit: number, contexts?: Context[]): SearchHit[] {
  const match = ftsQuery(query)
  if (!match) return []
  const filter = contextClause('s.context', contexts)
  return db.prepare(
    `SELECT s.id, s.clip, s.summary, s.text, s.created_at AS createdAt, s.happened, bm25(segments_fts) AS rank
     FROM segments_fts JOIN segments s ON s.id = segments_fts.rowid
     WHERE segments_fts MATCH ? AND s.superseded_by IS NULL${filter.sql} ORDER BY rank LIMIT ?`,
  ).all(match, ...filter.params, limit) as unknown as SearchHit[]
}

/**
 * Current notes about the dates from..to (YYYY-MM-DD, inclusive), newest first: when they happened, or else the day they
 * were written. Imported notes were all written on the import day, so for them only "happened" counts.
 */
export function inWindow(db: DatabaseSync, from: string, to: string, limit: number, contexts?: Context[]): SearchHit[] {
  const filter = contextClause('s.context', contexts)
  const when = "COALESCE(NULLIF(s.happened, ''), CASE WHEN s.clip LIKE 'import:%' THEN NULL ELSE date(s.created_at, 'localtime') END)"
  // "2024" and "2024-06" cover a whole year or month: they count when that span overlaps the window.
  const start = `CASE length(${when}) WHEN 4 THEN ${when} || '-01-01' WHEN 7 THEN ${when} || '-01' ELSE ${when} END`
  const end = `CASE length(${when}) WHEN 4 THEN ${when} || '-12-31' WHEN 7 THEN ${when} || '-31' ELSE ${when} END`
  return db.prepare(
    `SELECT s.id, s.clip, s.summary, s.text, s.created_at AS createdAt, s.happened, 0 AS rank FROM segments s
     WHERE s.superseded_by IS NULL AND ${when} IS NOT NULL AND ${start} <= ? AND ${end} >= ?${filter.sql}
     ORDER BY ${start} DESC LIMIT ?`,
  ).all(to, from, ...filter.params, limit) as unknown as SearchHit[]
}

/** The meaning-search model (see embed.ts). */
export const EMBED_MODEL = 'multilingual-e5-small'

/** Current notes with no vector from this model yet, oldest first. */
export function unembedded(db: DatabaseSync, model: string, limit: number): { id: number; text: string; summary: string }[] {
  return db.prepare('SELECT id, text, summary FROM segments WHERE superseded_by IS NULL AND embedded_with != ? ORDER BY id LIMIT ?')
    .all(model, limit) as { id: number; text: string; summary: string }[]
}

export function saveEmbedding(db: DatabaseSync, id: number, vector: Float32Array, model: string): void {
  db.prepare('UPDATE segments SET embedding = ?, embedded_with = ? WHERE id = ?').run(new Uint8Array(vector.buffer, vector.byteOffset, vector.byteLength), model, id)
}

/**
 * Notes closest in meaning to the question's vector, best first, above a similarity floor so small talk finds nothing.
 * ponytail: scans every vector (about 1 ms per thousand notes); an index only if memory grows past ~100k notes.
 */
export function similar(db: DatabaseSync, query: Float32Array, model: string, limit: number, floor: number, contexts?: Context[]): SearchHit[] {
  const filter = contextClause('s.context', contexts)
  const rows = db.prepare(
    `SELECT s.id, s.clip, s.summary, s.text, s.created_at AS createdAt, s.happened, s.embedding FROM segments s
     WHERE s.superseded_by IS NULL AND s.embedded_with = ?${filter.sql}`,
  ).all(model, ...filter.params) as unknown as (SearchHit & { embedding: Uint8Array })[]
  return rows
    .map(({ embedding, ...hit }) => {
      const v = new Float32Array(embedding.buffer, embedding.byteOffset, embedding.byteLength / 4)
      let score = 0
      for (let i = 0; i < v.length; i++) score += v[i] * query[i]
      return { ...hit, rank: -score }
    })
    .filter((h) => -h.rank >= floor)
    .sort((a, b) => a.rank - b.rank)
    .slice(0, limit)
}

export const TODO_STATUSES = ['open', 'done', 'dropped'] as const
export type TodoStatus = (typeof TODO_STATUSES)[number]
export interface TodoRow { id: number; text: string; owner: string | null; status: TodoStatus; context: Context; createdAt: string }

/** Action items from current notes in the given spaces: open ones first, newest first. */
export function listTodos(db: DatabaseSync, contexts: Context[]): TodoRow[] {
  const filter = contextClause('s.context', contexts)
  return db.prepare(`SELECT a.id, a.text, a.owner, a.status, s.context, s.created_at AS createdAt
    FROM actions a JOIN segments s ON s.id = a.segment_id WHERE s.superseded_by IS NULL${filter.sql}
    ORDER BY a.status = 'open' DESC, a.id DESC`).all(...filter.params) as unknown as TodoRow[]
}

export function setTodoStatus(db: DatabaseSync, id: number, status: TodoStatus): void {
  if (!TODO_STATUSES.includes(status)) throw new Error('status must be open, done or dropped')
  db.prepare('UPDATE actions SET status = ? WHERE id = ?').run(status, id)
}

export interface NoteRow { id: number; summary: string; context: Context; createdAt: string; happened: string; replaced: boolean }

/** Every note in the given spaces, newest first, including replaced ones, so any of them can be reviewed and forgotten. */
export function listNotes(db: DatabaseSync, contexts: Context[], limit: number): NoteRow[] {
  const filter = contextClause('context', contexts)
  const rows = db.prepare(`SELECT id, summary, context, created_at AS createdAt, happened, superseded_by IS NOT NULL AS replaced FROM segments
    WHERE 1 = 1${filter.sql} ORDER BY id DESC LIMIT ?`).all(...filter.params, limit) as { id: number; summary: string; context: Context; createdAt: string; happened: string; replaced: number }[]
  return rows.map((r) => ({ ...r, replaced: r.replaced === 1 }))
}

/** Marks older notes as replaced by a newer one. Returns how many changed. */
export function supersede(db: DatabaseSync, newer: number, older: number[]): number {
  let n = 0
  for (const id of older) n += Number(db.prepare('UPDATE segments SET superseded_by = ? WHERE id = ? AND id != ? AND superseded_by IS NULL').run(newer, id, newer).changes)
  return n
}

/** Undoes a replacement, from the Memory screen. */
export function restoreNote(db: DatabaseSync, id: number): void {
  db.prepare('UPDATE segments SET superseded_by = NULL WHERE id = ?').run(id)
}

export function graphData(db: DatabaseSync, contexts?: Context[]): GraphData {
  const nodeFilter = contextClause('s.context', contexts)
  const rows = db.prepare(
    `SELECT e.id, e.name, e.type, count(m.segment_id) AS mentions, group_concat(DISTINCT s.context) AS ctx
     FROM entities e JOIN mentions m ON m.entity_id = e.id JOIN segments s ON s.id = m.segment_id
     WHERE s.superseded_by IS NULL${nodeFilter.sql} GROUP BY e.id`,
  ).all(...nodeFilter.params) as unknown as { id: number; name: string; type: string; mentions: number; ctx: string }[]
  const nodes = rows.map((r) => ({ id: r.id, name: r.name, type: r.type, mentions: r.mentions, contexts: r.ctx.split(',').sort() as Context[] }))

  const edgeFilter = contextClause('s.context', contexts)
  const edges = db.prepare(
    `SELECT e.src AS source, e.dst AS target, e.rel AS relation, e.segment_id AS segment, s.context AS context
     FROM edges e JOIN segments s ON s.id = e.segment_id WHERE s.superseded_by IS NULL${edgeFilter.sql}`,
  ).all(...edgeFilter.params) as unknown as GraphData['edges']
  return { nodes, edges }
}
