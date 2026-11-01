// The three things Jarvis never does on its own: delete, spend money, or send the user's information anywhere. The
// words live in never.json (Jarvis Hands reads the same file), and every tool that acts checks them in code, so neither
// the model nor a page or message can talk it into one. A refusal is final: there is no "ask the user" path.
import { readFileSync } from 'node:fs'

interface Rules { delete: string[]; money: string[]; send: string[]; moneySites: string[]; numbers: { pattern: string; minDigits: number; dates: string }; personal: string[] }
const rules = JSON.parse(readFileSync(new URL('./never.json', import.meta.url), 'utf8')) as Rules
export type Never = 'delete' | 'money' | 'send'
const KINDS: Never[] = ['delete', 'money', 'send']

/** Lowercase words, with camelCase and snake_case split ("GMAIL_SEND_EMAIL", "sendMessage" -> send). */
const words = (text: string): string[] => text.replace(/([a-z])([A-Z])/g, '$1 $2').toLowerCase().split(/[^a-z0-9]+/).filter(Boolean)
const SUFFIXES = ['s', 'es', 'd', 'ed', 'ing']
const same = (w: string, p: string): boolean => w === p || SUFFIXES.some((s) => w === p + s) || (p.endsWith('e') && w === p.slice(0, -1) + 'ing')
const has = (ws: string[], phrase: string): boolean => {
  const ps = phrase.split(' ')
  return ws.some((_, i) => ps.every((p, j) => i + j < ws.length && same(ws[i + j], p)))
}

/** Which of the three this label, tool name or command would do, if any. */
export function never(text: string): Never | undefined {
  const ws = words(text)
  return KINDS.find((k) => rules[k].some((p) => has(ws, p)))
}

/** A phone, card or ID number, an email address, a PAN or an SSN: never typed or sent by Jarvis itself. */
export function personal(text: string): boolean {
  return longNumber(text) || rules.personal.some((p) => new RegExp(p, 'u').test(text))
}

function longNumber(text: string): boolean {
  const plain = text.replace(new RegExp(rules.numbers.dates, 'gu'), ' ') // dates and times are not phone numbers
  const runs = plain.match(new RegExp(rules.numbers.pattern, 'gu')) ?? []
  return runs.some((r) => r.replace(/\P{Nd}/gu, '').length >= rules.numbers.minDigits)
}

/** Keys, tokens and codes: an API key, a GitHub, AWS or Slack token, or "password: ...", "code is 123456". */
const SECRETS = [/\b(sk-[A-Za-z0-9_-]{16,}|gh[pousr]_[A-Za-z0-9]{20,}|AKIA[0-9A-Z]{16}|xox[abposr]-[A-Za-z0-9-]{10,})/,
  /\b(password|passcode|passwd|otp|one[- ]time (pass)?code|verification code|security code|pin)\b\W{0,4}(is\W{0,2})?\S{4,}/i,
  /\bcode\b\W{0,4}(is\W{0,2})?\d{4,8}\b/i,
  /\b\d{4,8}\b\W{0,6}(is\W{0,3})?(your\W+)?([\w-]+\W+){0,2}(code|otp|passcode|pin)\b/i]

/** What makes a conversation sensitive once a tool brings it in: a phone, card or ID number, a PAN or SSN, or a
 * secret. Email addresses alone do not (every inbox read has them). */
export function sensitive(text: string): boolean {
  return longNumber(text) || rules.personal.slice(1).some((p) => new RegExp(p, 'u').test(text)) || SECRETS.some((r) => r.test(text))
}

/** A payment, shop-checkout or bank page, by its host and path (not the query, so a search about paying is fine). */
export function moneySite(url: string): boolean {
  let u: URL
  try { u = new URL(url) } catch { return false }
  const parts = [...u.hostname.toLowerCase().split('.'), ...(() => { try { return decodeURIComponent(u.pathname) } catch { return u.pathname } })().toLowerCase().split(/[^a-z0-9]+/)]
  return parts.some((p) => rules.moneySites.includes(p))
}

const WHAT: Record<Never, string> = { delete: 'deletes anything', money: 'buys, pays or does anything with money', send: 'sends, posts, shares or uploads anything' }
/** The tool result for a refusal: final, and it tells the model to hand the step to the user. */
export const refused = (kind: Never): string =>
  `Refused: Jarvis never ${WHAT[kind]}, and no one can approve it. Do not try another way. Tell the user exactly what is ready and that this last step is theirs to do.`
