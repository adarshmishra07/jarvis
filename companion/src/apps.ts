import type { McpServer } from './mcp.ts'

// The apps you can connect through Composio, shown as a list in Settings. Connecting opens Composio's sign-in page;
// an app can have several accounts (for example work and personal Gmail), each with a label.

export const APPS = [
  { slug: 'gmail', name: 'Gmail', group: 'Google Workspace', about: 'Read, search, draft and send email' },
  { slug: 'googlecalendar', name: 'Google Calendar', group: 'Google Workspace', about: 'See your schedule, find free time, create and change events' },
  { slug: 'googledrive', name: 'Google Drive', group: 'Google Workspace', about: 'Find and read files and folders' },
  { slug: 'googledocs', name: 'Google Docs', group: 'Google Workspace', about: 'Read and write documents' },
  { slug: 'googlesheets', name: 'Google Sheets', group: 'Google Workspace', about: 'Read and update spreadsheets' },
  { slug: 'slack', name: 'Slack', group: '', about: 'Read and search conversations; send messages and reminders' },
  { slug: 'linear', name: 'Linear', group: '', about: 'Search and update issues; create issues and comments' },
  { slug: 'notion', name: 'Notion', group: '', about: 'Search, read and manage pages and databases' },
  { slug: 'github', name: 'GitHub', group: '', about: 'Read repositories, issues and pull requests; create issues and comments' },
  { slug: 'jira', name: 'Jira', group: '', about: 'Search and update tickets' },
  { slug: 'outlook', name: 'Outlook', group: '', about: 'Read, search, draft and send Outlook mail' },
  { slug: 'discord', name: 'Discord', group: '', about: 'Read and send messages in your servers' },
  { slug: 'hubspot', name: 'HubSpot', group: '', about: 'Look up and update contacts, companies and deals' },
  { slug: 'figma', name: 'Figma', group: '', about: 'Read files, frames and comments' },
  { slug: 'zoom', name: 'Zoom', group: '', about: 'See and schedule meetings; read recordings' },
  { slug: 'calendly', name: 'Calendly', group: '', about: 'See bookings and share scheduling links' },
] as const

export interface AppAccount { id: string; status: string; alias: string; who: string }

const EMAIL = /^[^\s@]+@[^\s@]+\.[^\s@]+$/
/** Which account this is (an email or user name), from the profile the app sends back. Only this one field is kept:
 * the profile can carry much more (a calendar's events, for example). */
function who(info: unknown): string {
  if (!info || typeof info !== 'object') return ''
  const o = info as Record<string, unknown>
  for (const k of ['email', 'emailAddress', 'mail', 'login', 'username', 'user_name', 'name', 'summary']) {
    const v = o[k]
    if (typeof v === 'string' && v.trim() && (k !== 'summary' || EMAIL.test(v.trim()))) return v.trim().slice(0, 80)
  }
  return ''
}
export interface AppRow { slug: string; name: string; group: string; about: string; connected: boolean; accounts: AppAccount[] }

async function manage(server: McpServer, toolkits: object[]): Promise<any> {
  const text = await server.call('COMPOSIO_MANAGE_CONNECTIONS', { toolkits })
  const reply = JSON.parse(text) as { successful?: boolean; data?: unknown; error?: unknown }
  if (reply.successful === false) throw new Error('Composio could not do that')
  return reply.data
}

export async function listApps(server: McpServer): Promise<AppRow[]> {
  const data = await manage(server, APPS.map((a) => ({ name: a.slug, action: 'list' })))
  const results = (data?.results ?? {}) as Record<string, { accounts?: { id?: string; status?: string; alias?: string; user_info?: unknown }[] }>
  return APPS.map((a) => {
    const accounts = (results[a.slug]?.accounts ?? []).map((x) => ({ id: String(x.id ?? ''), status: String(x.status ?? '').toUpperCase(), alias: String(x.alias ?? ''), who: who(x.user_info) }))
    return { slug: a.slug, name: a.name, group: a.group, about: a.about, connected: accounts.some((x) => x.status === 'ACTIVE'), accounts }
  })
}

const known = (slug: string): boolean => APPS.some((a) => a.slug === slug)

/** A sign-in link to connect (another) account of this app. */
export async function connectApp(server: McpServer, slug: string, alias?: string): Promise<string> {
  if (!known(slug)) throw new Error('unknown app')
  const label = alias?.trim().slice(0, 40)
  const data = await manage(server, [{ name: slug, action: 'add', ...(label ? { alias: label } : {}) }])
  let link = ''
  const walk = (o: unknown): void => {
    if (!o || typeof o !== 'object') return
    for (const [k, v] of Object.entries(o)) {
      if (!link && typeof v === 'string' && /redirect|link|url/i.test(k) && v.startsWith('https://')) link = v
      else walk(v)
    }
  }
  walk(data)
  if (!link) throw new Error('no sign-in link came back')
  return link
}

export async function removeApp(server: McpServer, slug: string, accountId: string): Promise<void> {
  if (!known(slug) || !/^[\w-]{1,80}$/.test(accountId)) throw new Error('unknown account')
  await manage(server, [{ name: slug, action: 'remove', account_id: accountId }])
}

export async function renameApp(server: McpServer, slug: string, accountId: string, alias: string): Promise<void> {
  const label = alias.trim().slice(0, 40)
  if (!known(slug) || !/^[\w-]{1,80}$/.test(accountId) || !label) throw new Error('give the account a label')
  await manage(server, [{ name: slug, action: 'rename', account_id: accountId, alias: label }])
}
