import { test } from 'node:test'
import assert from 'node:assert/strict'
import { openDb, search, graphData } from './db.ts'
import { seedProfile, type Profile } from './profile.ts'

const profile: Profile = {
  about: ['Sam works at Acme.', 'Riya is the engineering manager.', 'Leo and Mia are the founders.', 'Jordan is the partner; keep that private.'],
  seed: {
    text: 'Leo and Mia are the founders of Acme. Riya is the engineering manager.',
    summary: 'Acme people and environments.',
    entities: [
      { name: 'Acme', type: 'company' }, { name: 'Riya', type: 'person' }, { name: 'Leo', type: 'person' },
      { name: 'Mia', type: 'person' }, { name: 'Prod', type: 'tool' },
    ],
    edges: [
      { source: 'Riya', relation: 'engineering_manager_at', target: 'Acme' },
      { source: 'Leo', relation: 'founder_of', target: 'Acme' },
      { source: 'Mia', relation: 'founder_of', target: 'Acme' },
      { source: 'Acme', relation: 'has_environment', target: 'Prod' },
    ],
  },
}

test('seeding stores the profile as a searchable segment with entities and edges', () => {
  const db = openDb(':memory:')
  seedProfile(db, profile)
  assert.equal(search(db, 'founders', 5)[0].clip, 'profile')
  const g = graphData(db)
  assert.deepEqual(g.nodes.map((n) => n.name).sort(), ['Acme', 'Leo', 'Mia', 'Prod', 'Riya'])
  assert.equal(g.edges.length, 4)
})

test('seeding twice leaves exactly one profile segment and no duplicate edges', () => {
  const db = openDb(':memory:')
  seedProfile(db, profile)
  seedProfile(db, profile)
  assert.equal(graphData(db).edges.length, 4)
  assert.equal((db.prepare("SELECT count(*) AS n FROM segments WHERE clip = 'profile'").get() as { n: number }).n, 1)
})

test('guidance-only lines in about are never stored or searchable, only the seed text is', () => {
  const db = openDb(':memory:')
  seedProfile(db, profile)
  assert.deepEqual(search(db, 'Jordan partner', 5), [])
  const stored = (db.prepare("SELECT text FROM segments WHERE clip = 'profile'").get() as { text: string }).text
  assert.equal(stored, profile.seed.text)
})

const withPartner: Profile = {
  ...profile,
  personalSeed: {
    text: 'Jordan is my partner. I also call her Jo, Bee, babe or baby.',
    summary: 'Jordan, the partner.',
    entities: [{ name: 'Jordan', type: 'person' }],
    edges: [{ source: 'Sam Rivera', relation: 'partner_of', target: 'Jordan' }],
  },
}

test('the partner is stored in the personal space only, so work questions and the default graph never see her', () => {
  const db = openDb(':memory:')
  seedProfile(db, withPartner)
  assert.deepEqual(search(db, 'Jordan', 5, ['company', 'professional']), [])
  assert.equal(search(db, 'Bee', 5, ['personal'])[0].clip, 'profile-personal')
  assert.ok(!graphData(db, ['company', 'professional']).nodes.some((n) => n.name === 'Jordan'))
  assert.deepEqual(graphData(db, ['personal']).nodes.find((n) => n.name === 'Jordan')?.contexts, ['personal'])
})

test('seeding the partner twice leaves one personal segment', () => {
  const db = openDb(':memory:')
  seedProfile(db, withPartner)
  seedProfile(db, withPartner)
  assert.equal((db.prepare("SELECT count(*) AS n FROM segments WHERE clip = 'profile-personal'").get() as { n: number }).n, 1)
})
