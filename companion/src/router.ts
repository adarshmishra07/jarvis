// Routes a user question to a Claude tier using TypeSafe's Jev decision model.
// Policy logic follows the documented behavior of the aitmpl/davila7 jev-model-router
// mod (re-implemented, not copied). Only the question text is ever sent.

export type Model = 'claude-haiku-5-5' | 'claude-sonnet-5-5' | 'claude-opus-5-5'
export type Effort = 'low' | 'medium' | 'high' | 'xhigh'

export interface Route {
  model: Model
  effort: Effort
  reason: string
  /** The answer needs current or outside facts from the web. */
  web: boolean
}

export interface RouteDeps {
  fetch: typeof fetch
  apiKey: string
  baseUrl?: string
  timeoutMs?: number
}

const DEFAULT_BASE_URL = 'https://api.typesafe.ai'
const DEFAULT_TIMEOUT_MS = 800
const MIN_UPGRADE_CONFIDENCE = 0.3
const MIN_DOWNGRADE_CONFIDENCE = 0.6
const RISKY_THRESHOLD = 0.7

const TIER_MODEL: Record<string, Model> = {
  fast: 'claude-haiku-5-5',
  balanced: 'claude-sonnet-5-5',
  deep: 'claude-opus-5-5',
}
const EFFORTS: readonly Effort[] = ['low', 'medium', 'high', 'xhigh']

const FALLBACK: Route = { model: 'claude-sonnet-5-5', effort: 'medium', reason: 'fallback: kept sonnet', web: false }
const WEB_THRESHOLD = 0.5

const QUESTIONS = {
  tier: {
    type: 'choice',
    instructions: 'Which tier should handle this message to a personal assistant? Policy: fast for reading and simple stuff, balanced for everything else, deep only for complex problems.',
    criteria: {
      fast: 'Reading or recall: look something up in my notes or memory, read a file, a quick fact, a date or a name, a yes/no check, small talk, a one-line answer.',
      balanced:
        'Everything else: explaining, researching with the web, summarizing, drafting a message, comparing options, giving advice, answers that combine memory with outside knowledge.',
      deep: 'Complex problems: hard multi-step reasoning, planning or strategy, difficult technical or analytical work, or high stakes such as money, legal, health, or irreversible actions.',
    },
  },
  effort: {
    type: 'score',
    instructions: 'How much step-by-step reasoning does this request need?',
    criteria: ['almost none', 'some', 'a lot', 'as much as possible'],
  },
  web: {
    type: 'noul',
    instructions:
      'Answering this message well needs current or outside facts from the web: news, prices, weather, sports, releases, product docs, places, or anything that changes over time. Questions about the user\'s own life, notes or plans, small talk, and general knowledge that does not change do not need it.',
  },
  risky: {
    type: 'noul',
    instructions:
      'Carrying out this request would send a message, create or change a ticket, or move money or data in a way that cannot easily be undone. Answering a question or drafting text without sending it does not count.',
  },
} as const

interface Decision {
  tier: string
  confidence: number | null
  risky: number | null
  effortScore: number | null
  web: number | null
}

function readDecision(raw: unknown): Decision | null {
  const answers = (raw as { answers?: Record<string, Record<string, unknown>> } | null)?.answers
  const tier = answers?.tier
  if (!tier || typeof tier.choice !== 'string' || !(tier.choice in TIER_MODEL)) return null

  const probabilities = tier.probabilities as Record<string, number> | undefined
  const confidence =
    typeof tier.confidence === 'number'
      ? tier.confidence
      : probabilities
        ? Math.max(...Object.values(probabilities))
        : null

  const risky = typeof answers?.risky?.noul === 'number' ? answers.risky.noul : null
  const effortScore = typeof answers?.effort?.score === 'number' ? answers.effort.score : null
  const web = typeof answers?.web?.noul === 'number' ? answers.web.noul : null
  return { tier: tier.choice, confidence, risky, effortScore, web }
}

function effortFor(score: number | null, floor = 0): Effort {
  const level = Math.max(floor, Math.min(3, Math.round(score ?? 1)))
  return EFFORTS[level]
}

function decide(d: Decision): Omit<Route, 'web'> {
  if (d.risky !== null && d.risky > RISKY_THRESHOLD) {
    return { model: TIER_MODEL.deep, effort: effortFor(d.effortScore, 2), reason: `risky ${d.risky}: forced opus` }
  }

  const target = TIER_MODEL[d.tier]
  const effort = effortFor(d.effortScore)
  const conf = d.confidence

  if (target === FALLBACK.model) return { model: target, effort, reason: `balanced (${conf ?? 'n/a'})` }
  if (d.tier === 'fast') {
    const allowed = conf !== null && conf >= MIN_DOWNGRADE_CONFIDENCE
    return allowed
      ? { model: target, effort, reason: `fast (${conf})` }
      : { model: FALLBACK.model, effort, reason: `kept sonnet: fast wanted at ${conf ?? 'n/a'}` }
  }
  const allowed = conf === null || conf >= MIN_UPGRADE_CONFIDENCE
  return allowed
    ? { model: target, effort, reason: `deep (${conf ?? 'n/a'})` }
    : { model: FALLBACK.model, effort, reason: `kept sonnet: deep wanted at ${conf}` }
}

export async function route(question: string, deps: RouteDeps): Promise<Route> {
  if (!deps.apiKey) return FALLBACK // no TypeSafe key: every answer uses Sonnet
  const controller = new AbortController()
  const timer = setTimeout(() => controller.abort(), deps.timeoutMs ?? DEFAULT_TIMEOUT_MS)
  try {
    const response = await deps.fetch(`${deps.baseUrl ?? DEFAULT_BASE_URL}/v1/systemone`, {
      method: 'POST',
      headers: { 'content-type': 'application/json', authorization: `Bearer ${deps.apiKey}` },
      body: JSON.stringify({ model: 'jev-latest', state: question, questions: QUESTIONS }),
      signal: controller.signal,
    })
    if (!response.ok) return FALLBACK
    const decision = readDecision(await response.json())
    return decision ? { ...decide(decision), web: (decision.web ?? 0) > WEB_THRESHOLD } : FALLBACK
  } catch {
    return FALLBACK // timeout, network error, or unreadable body: never block the user
  } finally {
    clearTimeout(timer)
  }
}
