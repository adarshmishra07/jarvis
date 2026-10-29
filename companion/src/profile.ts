import type { DatabaseSync } from 'node:sqlite'
import { insertExtraction, deleteSegment, type Context, type Extraction } from './db.ts'

/** Facts the user told us directly. `about` is background for the extraction prompt only and is never stored. */
export interface Profile {
  about: string[]
  /** What gets stored and searched. Keep private guidance out of this text; it goes only in `about`. */
  seed: ProfileSeed
  /** Stored in the personal space only: hidden from work questions and from the default graph. */
  personalSeed?: ProfileSeed
}

export type ProfileSeed = Pick<Extraction, 'summary' | 'entities' | 'edges'> & { text: string }

function store(db: DatabaseSync, clip: string, context: Context, seed: ProfileSeed): void {
  const existing = db.prepare('SELECT id FROM segments WHERE clip = ?').get(clip) as { id: number } | undefined
  if (existing) deleteSegment(db, existing.id)
  insertExtraction(db, clip, seed.text, {
    keep: true,
    reason: 'user-provided profile',
    sensitivity: 'none',
    context,
    summary: seed.summary,
    entities: seed.entities,
    edges: seed.edges,
    action_items: [],
  })
}

/** Stores the profile as searchable segments with their entities and edges. Safe to run repeatedly. */
export function seedProfile(db: DatabaseSync, profile: Profile): void {
  store(db, 'profile', 'professional', profile.seed)
  if (profile.personalSeed) store(db, 'profile-personal', 'personal', profile.personalSeed)
}
