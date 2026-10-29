import type { DatabaseSync } from 'node:sqlite'
import type { ToolKit } from './agent.ts'

// Reminders and scheduled jobs. The companion keeps the clock (it runs in the background all the time); when one is due
// the app notifies you, and a job ("every weekday at 8, summarize my unread email") runs as a background task.

export const REPEATS = ['daily', 'weekdays', 'weekly', 'monthly'] as const
export type Repeat = (typeof REPEATS)[number]
export interface Reminder { id: number; text: string; dueAt: string; repeat: Repeat | null; run: boolean }

const MAX_TEXT = 500
const GRACE_MS = 60_000 // "now" said a moment ago is not the past

/** The next time after `now`, skipping occurrences missed while the Mac was off. Local time, so 9:00 stays 9:00. */
export function nextDue(due: Date, repeat: Repeat, now: Date): Date {
  const d = new Date(due)
  while (d <= now) {
    if (repeat === 'daily') d.setDate(d.getDate() + 1)
    else if (repeat === 'weekly') d.setDate(d.getDate() + 7)
    else if (repeat === 'weekdays') do d.setDate(d.getDate() + 1); while (d.getDay() === 0 || d.getDay() === 6)
    else {
      // ponytail: a month without the day (31st) moves it to the last day and it stays there; store the day if that matters.
      const day = d.getDate()
      d.setDate(1); d.setMonth(d.getMonth() + 1)
      d.setDate(Math.min(day, new Date(d.getFullYear(), d.getMonth() + 1, 0).getDate()))
    }
  }
  return d
}

export class Reminders {
  private readonly db: DatabaseSync
  private readonly now: () => Date

  constructor(db: DatabaseSync, now: () => Date = () => new Date()) {
    this.db = db
    this.now = now
    db.exec(`CREATE TABLE IF NOT EXISTS reminders (id INTEGER PRIMARY KEY, text TEXT NOT NULL, due_at TEXT NOT NULL, repeat TEXT,
      run INTEGER NOT NULL DEFAULT 0, status TEXT NOT NULL DEFAULT 'pending', created_at TEXT NOT NULL)`)
  }

  add(input: { text: string; at: string; repeat?: Repeat; run?: boolean }): Reminder {
    const text = String(input.text ?? '').trim().slice(0, MAX_TEXT)
    if (!text) throw new Error('say what to remind about')
    if (!/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}/.test(String(input.at ?? ''))) throw new Error('at must be a local date and time, like 2026-10-23T09:00')
    const at = new Date(input.at)
    if (Number.isNaN(at.getTime())) throw new Error('at must be a local date and time, like 2026-10-23T09:00')
    const repeat = input.repeat ?? null
    if (repeat !== null && !REPEATS.includes(repeat)) throw new Error(`repeat must be one of ${REPEATS.join(', ')}`)
    const now = this.now()
    if (at.getTime() < now.getTime() - GRACE_MS && !repeat) throw new Error('that time is in the past')
    const due = repeat && at < now ? nextDue(at, repeat, now) : at
    const row = this.db.prepare('INSERT INTO reminders (text, due_at, repeat, run, created_at) VALUES (?, ?, ?, ?, ?) RETURNING id')
      .get(text, due.toISOString(), repeat, input.run ? 1 : 0, now.toISOString()) as { id: number }
    return { id: row.id, text, dueAt: due.toISOString(), repeat, run: Boolean(input.run) }
  }

  /** Waiting reminders, soonest first. */
  list(): Reminder[] { return this.select("status = 'pending' ORDER BY due_at") }

  /** Reminders whose time has come and that have not gone off yet. */
  due(): Reminder[] { return this.select("status = 'pending' AND due_at <= ? ORDER BY due_at", this.now().toISOString()) }

  /** It went off: a repeating one moves to its next time, a one-off is finished. */
  fired(id: number): void {
    const r = this.select('id = ?', id)[0]
    if (!r) return
    if (r.repeat) this.db.prepare('UPDATE reminders SET due_at = ? WHERE id = ?').run(nextDue(new Date(r.dueAt), r.repeat, this.now()).toISOString(), id)
    else this.db.prepare("UPDATE reminders SET status = 'fired' WHERE id = ?").run(id)
  }

  snooze(id: number, minutes: number): void {
    const until = new Date(this.now().getTime() + Math.max(1, Math.min(minutes, 24 * 60)) * 60_000)
    this.db.prepare("UPDATE reminders SET due_at = ?, status = 'pending' WHERE id = ?").run(until.toISOString(), id)
  }

  cancel(id: number): boolean {
    return Number(this.db.prepare("UPDATE reminders SET status = 'cancelled' WHERE id = ? AND status = 'pending'").run(id).changes) > 0
  }

  private select(where: string, ...params: (string | number)[]): Reminder[] {
    const rows = this.db.prepare(`SELECT id, text, due_at AS dueAt, repeat, run FROM reminders WHERE ${where}`).all(...params) as
      { id: number; text: string; dueAt: string; repeat: Repeat | null; run: number }[]
    return rows.map((r) => ({ ...r, run: r.run === 1 }))
  }
}

const when = (iso: string): string => new Date(iso).toLocaleString('en-GB', { weekday: 'long', day: 'numeric', month: 'long', hour: 'numeric', minute: '2-digit', hour12: true })

export const REMINDER_GUIDE = `For "remind me", "every morning" and other things at a set time, use set_reminder. Work out \`at\` from Now as
a local date and time (2026-10-23T09:00). For a vague time ("tonight", "later") pick a sensible one and say which. When
something should be done at that time (look something up, summarize email), set run: true and write the text as a full
task a helper can do on its own. Confirm in one short sentence with the day and time.`

/** `scrub` keeps login details the user sent out of what is stored and shown later. A job (run: true) acts on its own
 * later and again on every repeat, so it is saved only with the user's yes: text in a page or an email cannot plant one. */
export function reminderTools(reminders: Reminders, scrub: (text: string) => string = (t) => t,
  approve: (action: string) => Promise<boolean> = async () => false): ToolKit {
  return {
    definitions: [
      { name: 'set_reminder', description: 'Remind the user at a time (a notification, spoken if they are at the Mac), once or repeating. With run: true, the text is a task done in the background at that time instead, and its report is shown.',
        input_schema: { type: 'object', properties: {
          text: { type: 'string', description: 'What to remind about, or the full task when run is true' },
          at: { type: 'string', description: 'Local date and time, like 2026-10-23T09:00' },
          repeat: { type: 'string', enum: [...REPEATS] },
          run: { type: 'boolean', description: 'Do the text as a background task at that time' },
        }, required: ['text', 'at'] } },
      { name: 'reminders', description: "The user's upcoming reminders and scheduled tasks.", input_schema: { type: 'object', properties: {} } },
      { name: 'cancel_reminder', description: 'Cancel an upcoming reminder or scheduled task by id.',
        input_schema: { type: 'object', properties: { id: { type: 'number' } }, required: ['id'] } },
    ],
    run: async (name, input) => {
      const args = input as { text?: string; at?: string; repeat?: Repeat; run?: boolean; id?: number }
      if (name === 'reminders') return JSON.stringify(reminders.list().map((r) => ({ ...r, dueAt: when(r.dueAt) })))
      if (name === 'cancel_reminder') return reminders.cancel(Number(args.id)) ? 'Cancelled.' : 'No upcoming reminder has that id.'
      const text = scrub(String(args.text ?? '')).trim()
      // What you approve is exactly what runs: the whole task is shown, and one too long to show is refused.
      if (text.length > MAX_TEXT) throw new Error(`keep it under ${MAX_TEXT} characters`)
      if (args.run === true && !(await approve(`Schedule a task${args.repeat ? ` (${args.repeat})` : ''} at ${String(args.at ?? '')}: ${text}`))) {
        return 'The user said no, so the task was not scheduled.'
      }
      const r = reminders.add({ text, at: String(args.at ?? ''), repeat: args.repeat, run: args.run === true })
      return `Set: "${r.text}" ${r.run ? 'runs' : 'is due'} ${when(r.dueAt)}${r.repeat ? `, repeating ${r.repeat}` : ''} (id ${r.id}).`
    },
  }
}
