// Memory recall eval: made-up notes and questions in a throwaway database, run through the same recall() and shown()
// that answers use. Prints only ids and scores. Run: npm run eval:recall [-- --words-only]
// Meaning search uses the model in PIKACHU_EMBED_MODEL, else the installed one; without it, words only.
import { existsSync } from 'node:fs'
import { homedir } from 'node:os'
import { join } from 'node:path'
import { openDb, insertExtraction, similar, EMBED_MODEL, type Context, type Extraction } from './db.ts'
import { recall, shown, graphFacts, MEANING_FLOOR } from './ask.ts'
import { embedMissing, loadEmbedder } from './embed.ts'

interface Note { clip: string; text: string; summary: string; context?: Context; keywords?: string[]; happened?: string; written?: string; entities?: string[]; edges?: [string, string, string][] }
interface Case { kind: string; q: string; want: string; terms?: string[]; fact?: string }

const NOW = new Date('2026-10-29T12:00:00') // a Thursday
const LONG_FILLER = 'We went through the agenda item by item and agreed to revisit the backlog grooming process next sprint. '.repeat(14)

const notes: Note[] = [
  { clip: 'atlas-owner', text: 'Asha leads the Atlas launch. It ships on Friday after the staging review.', summary: 'Asha leads Atlas, ships Friday', keywords: ['launch', 'release', 'ship', 'lead', 'owner'], entities: ['Asha', 'Atlas'], edges: [['Asha', 'leads', 'Atlas']] },
  { clip: 'orbit-api', text: 'Ravi owns the Orbit API and will send the pricing deck to Leo by Thursday.', summary: 'Ravi owns Orbit API, sends pricing deck', keywords: ['api', 'pricing', 'deck', 'slides', 'owner'], entities: ['Ravi', 'Orbit API', 'Leo'], edges: [['Ravi', 'owns', 'Orbit API']] },
  { clip: 'design', text: 'Mia runs design for Atlas and reviews every screen in Figma on Tuesdays.', summary: 'Mia runs Atlas design reviews in Figma', keywords: ['design', 'figma', 'review', 'ui', 'screens'], entities: ['Mia', 'Figma'], edges: [['Mia', 'designs', 'Atlas']] },
  { clip: 'em', text: 'Riya is the engineering manager for Atlas and Orbit API.', summary: 'Riya is engineering manager', keywords: ['manager', 'engineering', 'boss', 'reports'], entities: ['Riya'], edges: [['Riya', 'manages', 'Atlas']] },
  { clip: 'ai-team', text: 'The AI team is trialling a new evaluation harness for the support bot.', summary: 'AI team trials eval harness', keywords: ['ai', 'evaluation', 'bot', 'support'], entities: ['AI', 'Support bot'], edges: [['AI', 'builds', 'Support bot']] },
  { clip: 'go-svc', text: 'The billing service is written in Go and deployed with Kubernetes.', summary: 'Billing service in Go on Kubernetes', keywords: ['billing', 'golang', 'kubernetes', 'deploy'], entities: ['Go', 'Billing service'], edges: [['Billing service', 'written_in', 'Go']] },
  { clip: 'trip-zermatt', text: 'Weekend trip to Zermatt with college friends, took the train from Geneva.', summary: 'Zermatt trip with friends', context: 'personal', keywords: ['trip', 'travel', 'vacation', 'holiday', 'mountains', 'yatra', 'घूमने'], happened: '2024-06' },
  { clip: 'trip-goa', text: 'Spent four days in Goa for a cousin wedding, stayed near Candolim beach.', summary: 'Goa for cousin wedding', context: 'personal', keywords: ['trip', 'travel', 'wedding', 'beach', 'shaadi', 'family'], happened: '2025-12' },
  { clip: 'gym', text: 'Started going to the gym three times a week, mostly strength training.', summary: 'Gym three times a week', context: 'personal', keywords: ['gym', 'workout', 'exercise', 'fitness', 'kasrat'] },
  { clip: 'dentist', text: 'Dentist appointment moved to next Wednesday at 4 pm.', summary: 'Dentist moved to Wednesday 4 pm', context: 'personal', keywords: ['dentist', 'appointment', 'doctor', 'teeth'], written: '2026-10-27 10:00:00' },
  { clip: 'standup-mon', text: 'Monday standup: Atlas staging is green, two blockers left on payments.', summary: 'Standup: Atlas staging green, payment blockers', keywords: ['standup', 'status', 'blockers', 'payments'], written: '2026-10-26 04:30:00' },
  { clip: 'offsite', text: 'Booked the team offsite venue in the hills for the second week of November.', summary: 'Team offsite venue booked for November', keywords: ['offsite', 'team', 'venue', 'retreat', 'november'], written: '2026-10-21 09:00:00' },
  { clip: 'hiring', text: 'Opened two backend roles; Sam is screening candidates this month.', summary: 'Two backend roles open, Sam screening', keywords: ['hiring', 'recruiting', 'jobs', 'candidates', 'interviews'], written: '2026-09-15 09:00:00' },
  { clip: 'q3-review', text: 'Quarterly review: revenue grew 18 percent, churn flat, Atlas delayed by a month.', summary: 'Q3 review: revenue up 18%', keywords: ['quarterly', 'review', 'revenue', 'growth', 'churn'], written: '2026-10-02 09:00:00' },
  { clip: 'side-project', text: 'Building a reading tracker in Swift on weekends to learn concurrency.', summary: 'Reading tracker side project in Swift', context: 'professional', keywords: ['side project', 'swift', 'app', 'learning', 'reading'] },
  { clip: 'talk', text: 'Gave a talk on local-first apps at the Swift meetup in March.', summary: 'Talk on local-first apps at Swift meetup', context: 'professional', keywords: ['talk', 'meetup', 'speaking', 'presentation', 'conference'], happened: '2026-03' },
  { clip: 'import:notes.md#1', text: 'Joined Acme as a product engineer in 2023 after two years at a fintech startup.', summary: 'Joined Acme in 2023', context: 'professional', keywords: ['job', 'career', 'joined', 'work history'], happened: '2023', written: '2026-10-28 08:00:00' },
  { clip: 'import:notes.md#2', text: 'Favourite books: Thinking in Systems, The Pragmatic Programmer.', summary: 'Favourite books', context: 'personal', keywords: ['books', 'reading', 'favourite', 'kitaab'], written: '2026-10-28 08:00:00' },
  { clip: 'retro-long', text: `Sprint retro notes. ${LONG_FILLER} Decision: Leo will own the incident runbook from now on, and on-call moves to a weekly rotation.`, summary: 'Sprint retro', keywords: ['retro', 'sprint', 'retrospective', 'process'] },
  { clip: 'vendor-long', text: `Vendor call. ${LONG_FILLER} The contract renewal price is 42,000 dollars a year and it renews on 1 February.`, summary: 'Vendor call notes', keywords: ['vendor', 'contract', 'supplier', 'call'] },
  { clip: 'mom-bday', text: 'Mom birthday is on 14 November; order the cake from the bakery near home.', summary: 'Mom birthday 14 November', context: 'personal', keywords: ['birthday', 'mom', 'mother', 'cake', 'janamdin', 'मां'] },
  { clip: 'car', text: 'Car service due next month, the garage is near the office.', summary: 'Car service due', context: 'personal', keywords: ['car', 'service', 'garage', 'maintenance', 'gaadi'] },
]

const cases: Case[] = [
  // Asked with the note's own words
  { kind: 'direct', q: 'Who leads the Atlas launch?', want: 'atlas-owner' },
  { kind: 'direct', q: 'Who owns the Orbit API?', want: 'orbit-api' },
  { kind: 'direct', q: 'When is my dentist appointment?', want: 'dentist' },
  { kind: 'direct', q: 'What did the quarterly review say about revenue?', want: 'q3-review' },
  // Different words than the note (the planner's terms are used only when nothing matches, as in answers)
  { kind: 'paraphrase', q: 'Who is my boss?', want: 'em' },
  { kind: 'paraphrase', q: 'Where have I travelled?', want: 'trip-zermatt' },
  { kind: 'paraphrase', q: 'How often do I work out?', want: 'gym', terms: ['gym', 'workout', 'exercise', 'fitness'] },
  { kind: 'paraphrase', q: 'Who is making the slides about cost?', want: 'orbit-api', terms: ['slides', 'pricing', 'deck', 'presentation'] },
  { kind: 'paraphrase', q: 'Are we recruiting engineers?', want: 'hiring' },
  { kind: 'paraphrase', q: 'Which programming language is billing built with?', want: 'go-svc', terms: ['golang', 'language', 'billing', 'code'] },
  // Hindi and Hinglish
  { kind: 'hinglish', q: 'mummy ka janamdin kab hai?', want: 'mom-bday' },
  { kind: 'hinglish', q: 'main kahan kahan ghoomne gaya hoon?', want: 'trip-zermatt', terms: ['trip', 'travel', 'ghoomne', 'yatra'] },
  { kind: 'hinglish', q: 'gaadi ki service kab hai?', want: 'car' },
  { kind: 'hinglish', q: 'मेरी पसंदीदा किताबें कौन सी हैं?', want: 'import:notes.md#2', terms: ['books', 'kitaab', 'favourite'] },
  // When things happened
  { kind: 'date', q: 'What did I do last week?', want: 'offsite' },
  { kind: 'date', q: 'What happened this week?', want: 'standup-mon' },
  { kind: 'date', q: 'What was I up to in June 2024?', want: 'trip-zermatt' },
  { kind: 'date', q: 'What did I do in March?', want: 'talk' },
  { kind: 'date', q: 'pichle mahine kya hua tha?', want: 'hiring' },
  { kind: 'date', q: 'What happened in 2023?', want: 'import:notes.md#1' },
  // Facts deep inside long notes
  { kind: 'long', q: 'Who owns the incident runbook?', want: 'retro-long', fact: 'Leo will own the incident runbook' },
  { kind: 'long', q: 'How much is the vendor contract renewal?', want: 'vendor-long', fact: '42,000 dollars' },
]

/** Small talk and outside questions: no note should come back. */
const none = ['hi there', 'thanks a lot', 'tell me a joke', 'what is the capital of France?', 'how do I boil an egg?', 'kya haal hai?']

/** Questions whose graph facts must not drag in unrelated entities that only share letters ("AI" in "said"). */
const noise: { q: string; unrelated: string[] }[] = [
  { q: 'What did Asha said about the launch?', unrelated: ['AI ', 'Go]', '-> Go'] },
  { q: 'Is Ravi going to send the pricing deck?', unrelated: ['AI ', '-> Go'] },
]

const db = openDb(':memory:')
for (const n of notes) {
  const ex: Extraction = {
    keep: true, reason: '', sensitivity: 'none', context: n.context ?? 'company', summary: n.summary, keywords: n.keywords, happened: n.happened ?? '',
    entities: (n.entities ?? []).map((name) => ({ name, type: 'topic' })), edges: (n.edges ?? []).map(([source, relation, target]) => ({ source, relation, target })), action_items: [],
  }
  insertExtraction(db, n.clip, n.text, ex)
  db.prepare('UPDATE segments SET created_at = ? WHERE clip = ?').run(n.written ?? '2026-10-10 09:00:00', n.clip)
}

const spaces: Context[] = ['company', 'professional', 'personal']
const modelDir = process.env.PIKACHU_EMBED_MODEL ?? join(homedir(), 'Library', 'Application Support', 'agent-pikachu', 'models', EMBED_MODEL)
const embedder = !process.argv.includes('--words-only') && existsSync(modelDir) ? await loadEmbedder(modelDir) : undefined
if (embedder) while (await embedMissing(db, embedder)) { /* every note gets its vector */ }
const FLOOR = Number(process.env.FLOOR ?? MEANING_FLOOR)
console.log(embedder ? `meaning search on (floor ${FLOOR})` : 'words only')
const meaningOf = async (q: string): Promise<Float32Array | undefined> => embedder && (await embedder.embed([q], 'query'))[0]
const wantedScore: number[] = [], otherScore: number[] = []
const byKind = new Map<string, { n: number; top1: number; top5: number; fact: number; facts: number }>()
const misses: string[] = []
let ms = 0
for (const c of cases) {
  const start = performance.now()
  const meaning = await meaningOf(c.q)
  let hits = recall(db, c.q, [], spaces, NOW, meaning, FLOOR)
  let terms: string[] = []
  if (!hits.length && c.terms) { terms = c.terms; hits = recall(db, c.q, terms, spaces, NOW, meaning, FLOOR) }
  if (meaning) for (const h of similar(db, meaning, EMBED_MODEL, 50, -1, spaces)) (h.clip === c.want ? wantedScore : otherScore).push(-h.rank)
  ms += performance.now() - start
  const at = hits.slice(0, 5).findIndex((h) => h.clip === c.want)
  const k = byKind.get(c.kind) ?? { n: 0, top1: 0, top5: 0, fact: 0, facts: 0 }
  k.n++; if (at === 0) k.top1++; if (at >= 0) k.top5++
  if (c.fact) { k.facts++; if (at >= 0 && shown(hits[at].text, c.q, terms).includes(c.fact)) k.fact++ }
  byKind.set(c.kind, k)
  if (at < 0) misses.push(`${c.kind}: ${c.want}`)
}
let smallTalk = 0
const smallTalkScore: number[] = []
for (const q of none) {
  const meaning = await meaningOf(q)
  smallTalk += recall(db, q, [], spaces, NOW, meaning, FLOOR).length
  if (meaning) smallTalkScore.push(-similar(db, meaning, EMBED_MODEL, 1, -1, spaces)[0].rank)
}
let noisy = 0
for (const t of noise) noisy += graphFacts(db, t.q, spaces).filter((f) => t.unrelated.some((u) => f.includes(u))).length

let n = 0, top1 = 0, top5 = 0
for (const [kind, k] of byKind) {
  n += k.n; top1 += k.top1; top5 += k.top5
  console.log(`${kind.padEnd(10)} top-1 ${k.top1}/${k.n}  top-5 ${k.top5}/${k.n}${k.facts ? `  fact shown ${k.fact}/${k.facts}` : ''}`)
}
console.log(`${'all'.padEnd(10)} top-1 ${top1}/${n}  top-5 ${top5}/${n}  unrelated graph facts ${noisy}  ${(ms / cases.length).toFixed(1)} ms per question`)
console.log(`small talk: ${smallTalk} notes came back for ${none.length} questions that should find none`)
if (embedder) {
  const pct = (xs: number[], p: number): string => [...xs].sort((a, b) => a - b)[Math.min(xs.length - 1, Math.floor(p * xs.length))].toFixed(3)
  console.log(`meaning scores: wanted note min ${pct(wantedScore, 0)} median ${pct(wantedScore, 0.5)} | other notes median ${pct(otherScore, 0.5)} p95 ${pct(otherScore, 0.95)} | small talk best ${pct(smallTalkScore, 1)}`)
}
if (misses.length) console.log(`missed: ${misses.join(', ')}`)
