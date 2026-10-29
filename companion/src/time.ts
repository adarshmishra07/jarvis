// Dates for the model: what "now" is, and how old a note is. SQLite stores created_at in UTC.

const pad = (n: number): string => String(n).padStart(2, '0')

/** "Thursday, 22 October 2026, 13:30 (Asia/Kolkata)" in the Mac's own time zone. */
export function describeNow(d: Date, withZone = true): string {
  const day = d.toLocaleDateString('en-GB', { weekday: 'long' })
  const date = d.toLocaleDateString('en-GB', { day: 'numeric', month: 'long', year: 'numeric' })
  const zone = withZone ? ` (${Intl.DateTimeFormat().resolvedOptions().timeZone})` : ''
  return `${day}, ${date}, ${pad(d.getHours())}:${pad(d.getMinutes())}${zone}`
}

/** A SQLite UTC timestamp ("2026-10-20 09:00:00") as a Date. */
export const fromSqlite = (utc: string): Date => new Date(`${utc.replace(' ', 'T')}Z`)

const localDay = (d: Date): string => `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())}`

/** "written 2026-10-20, 2 days ago", by calendar day in local time. */
export function written(createdUtc: string, now: Date): string {
  const created = fromSqlite(createdUtc)
  const days = Math.round((Date.parse(localDay(now)) - Date.parse(localDay(created))) / 86_400_000)
  const ago = days <= 0 ? 'today' : days === 1 ? 'yesterday' : days < 60 ? `${days} days ago` : `${Math.round(days / 30)} months ago`
  return `written ${localDay(created)}, ${ago}`
}
