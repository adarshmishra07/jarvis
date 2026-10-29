import type { DatabaseSync } from 'node:sqlite'
import { graphData, CONTEXTS, type Context, type GraphData } from './db.ts'

export interface GraphWithDetails extends GraphData {
  details: Record<string, { name: string; type: string; segments: { id: number; summary: string; context: Context }[]; links: { relation: string; dir: 'in' | 'out'; other: string; context: Context }[] }>
}

/** Nodes, edges and per-node notes for the graph page. The page filters by space itself, so all spaces come by default. */
export function graphWithDetails(db: DatabaseSync, contexts: readonly Context[] = CONTEXTS): GraphWithDetails {
  const g = graphData(db, [...contexts])
  const segmentsOf = db.prepare('SELECT s.id, s.summary, s.context, s.happened FROM mentions m JOIN segments s ON s.id = m.segment_id WHERE m.entity_id = ? AND s.superseded_by IS NULL')
  const linksOf = db.prepare(
    `SELECT e.rel AS relation, 'out' AS dir, b.name AS other, s.context AS context FROM edges e JOIN entities b ON b.id = e.dst JOIN segments s ON s.id = e.segment_id WHERE e.src = ? AND s.superseded_by IS NULL
     UNION ALL
     SELECT e.rel, 'in', a.name, s.context FROM edges e JOIN entities a ON a.id = e.src JOIN segments s ON s.id = e.segment_id WHERE e.dst = ? AND s.superseded_by IS NULL`,
  )
  const details: GraphWithDetails['details'] = {}
  for (const n of g.nodes) {
    details[String(n.id)] = {
      name: n.name, type: n.type,
      segments: segmentsOf.all(n.id) as never,
      links: linksOf.all(n.id, n.id) as never,
    }
  }
  return { ...g, details }
}
