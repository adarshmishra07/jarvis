// Small, model-free helpers for what memory shows an answer: the matching part of a long note, names said as whole
// words, and the dates a question is about.

const word = (s: string): string[] => s.toLowerCase().split(/[^\p{L}\p{N}\p{M}]+/u).filter((w) => w.length > 2)

/** The part of a long note that best matches the question, so a fact deep in the note still reaches the answer. */
export function excerpt(text: string, words: string[], max: number): string {
  if (text.length <= max) return text
  const wanted = new Set(words.flatMap(word))
  const step = Math.max(50, Math.floor(max / 8))
  let best = 0, bestScore = -1
  for (let start = 0; start < text.length; start += step) {
    const window = word(text.slice(start, start + max))
    // Each wanted word counts once, matched on its first five letters so "owns" finds "own".
    const score = [...wanted].filter((w) => window.some((t) => t.slice(0, 5) === w.slice(0, 5))).length
    if (score > bestScore) { best = start; bestScore = score }
    if (start + max >= text.length) break
  }
  const from = Math.min(best, text.length - max)
  return `${from > 0 ? '…' : ''}${text.slice(from, from + max)}${from + max < text.length ? '…' : ''}`
}

/** Whether a name is said in the text as whole words: "AI" is in "the AI team", not in "said". */
export function mentions(text: string, name: string): boolean {
  if (name.trim().length < 2) return false
  const escaped = name.trim().replace(/[.*+?^${}()|[\]\\]/g, '\\$&')
  return new RegExp(`(?<![\\p{L}\\p{N}])${escaped}(?![\\p{L}\\p{N}])`, 'iu').test(text)
}

export interface DateWindow { from: string; to: string } // YYYY-MM-DD, both included

const MONTHS = ['january', 'february', 'march', 'april', 'may', 'june', 'july', 'august', 'september', 'october', 'november', 'december']
const day = (d: Date): string => `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}-${String(d.getDate()).padStart(2, '0')}`
const shift = (d: Date, days: number): Date => new Date(d.getFullYear(), d.getMonth(), d.getDate() + days)
const monthWindow = (y: number, m: number): DateWindow => ({ from: day(new Date(y, m, 1)), to: day(new Date(y, m + 1, 0)) })

/**
 * The dates a question asks about ("last week", "in March", "June 2024", "pichle mahine"), in local time, or null.
 * ponytail: a fixed phrase list; "kal" (yesterday or tomorrow) is left out on purpose. Add phrases when the eval misses them.
 */
export function dateWindow(question: string, now: Date): DateWindow | null {
  const q = question.toLowerCase()
  const has = (re: RegExp): boolean => re.test(q)
  const monday = shift(now, -((now.getDay() + 6) % 7))
  if (has(/\b(today|aaj)\b|आज/)) return { from: day(now), to: day(now) }
  if (has(/\byesterday\b/)) return { from: day(shift(now, -1)), to: day(shift(now, -1)) }
  if (has(/\b(this|is) (week|hafte)\b|इस हफ्ते/)) return { from: day(monday), to: day(now) }
  if (has(/\b(last|past|previous) week\b|\bpich+le hafte\b|पिछले हफ्ते/)) return { from: day(shift(monday, -7)), to: day(shift(monday, -1)) }
  if (has(/\b(this|is) (month|mahine)\b|इस महीने/)) return { from: day(new Date(now.getFullYear(), now.getMonth(), 1)), to: day(now) }
  if (has(/\b(last|past|previous) month\b|\bpich+le mahine\b|पिछले महीने/)) return monthWindow(now.getFullYear(), now.getMonth() - 1)
  if (has(/\b(this|is) (year|saal)\b|इस साल/)) return { from: `${now.getFullYear()}-01-01`, to: day(now) }
  if (has(/\b(last|past|previous) year\b|\bpich+le saal\b|पिछले साल/)) return { from: `${now.getFullYear() - 1}-01-01`, to: `${now.getFullYear() - 1}-12-31` }
  const days = q.match(/\b(?:last|past) (\d{1,3}) days\b/)
  if (days) return { from: day(shift(now, -Number(days[1]))), to: day(now) }
  const year = q.match(/\b(19\d{2}|20\d{2})\b/)?.[1]
  // A month by name ("may" only with "in", it is also a verb): that month of the year given, or its latest one so far.
  const m = MONTHS.findIndex((name) => new RegExp(name === 'may' ? '\\bin may\\b' : `\\b${name}\\b`).test(q))
  if (m >= 0) {
    const y = year ? Number(year) : m <= now.getMonth() ? now.getFullYear() : now.getFullYear() - 1
    return monthWindow(y, m)
  }
  if (year && has(new RegExp(`\\b(in|during|of|from)\\s+${year}\\b`))) return { from: `${year}-01-01`, to: `${year}-12-31` }
  return null
}
