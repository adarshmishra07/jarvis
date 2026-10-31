import net from 'node:net'
import { randomUUID } from 'node:crypto'
import { rmSync, chmodSync } from 'node:fs'
import type { DatabaseSync } from 'node:sqlite'
import { askStream, type AskDeps } from './ask.ts'
import { learnFromTurn, remember, type Spelling } from './learn.ts'
import { research } from './research.ts'
import { deleteSegment, restoreNote, listNotes, listTodos, setTodoStatus, TODO_STATUSES, type Context } from './db.ts'
import { graphWithDetails } from './graph.ts'
import { chunkMarkdown } from './chunk.ts'
import { decodeLines, encode, MAX_LINE_BYTES, type Event, type Request } from './protocol.ts'
import { ledgered, readLedger, recordVisit } from './ledger.ts'
import { combineTools, type ToolKit } from './agent.ts'
import { applyUpdate, updateStatus } from './update.ts'
import { TaskRunner } from './tasks.ts'
import { Reminders, reminderTools, REMINDER_GUIDE, type Reminder } from './reminders.ts'
import { controlTools, NOTES_GUIDE } from './control.ts'
import { writeMeetingNote, type TranscriptLine } from './meeting.ts'
import { MeetingMemory, meetingTools, MEETINGS_GUIDE } from './meetings.ts'
import { Watches, watchChecker, watchTools, WATCH_GUIDE, WATCH_TICK_MS } from './watches.ts'
import { backgroundWorker, taskTools, TASK_GUIDE } from './background.ts'
import { browserTools, BROWSER_GUIDE, type BrowserLike } from './browser-tools.ts'
import { BrowserSession, type SessionBrowser } from './browser-session.ts'
import { composioConnect, mcpTools, McpServer, MCP_GUIDE, NeedsSignIn, type McpConfig } from './mcp.ts'
import { McpOAuth } from './oauth.ts'
import { connectApp, listApps, removeApp, renameApp } from './apps.ts'
import { ImageGate } from './images.ts'
import { computerTools, COMPUTER_GUIDE, type HandsCall } from './computer.ts'
import { installSkill, SkillStore, skillTools, SKILLS_GUIDE } from './skills.ts'
import { fixSpelling, mergeAliases, respellMemory, type Spellings } from './spelling.ts'

export interface ServerDeps extends AskDeps {
  /** Application Support folder: staged updates and the installed version live here. */
  appHome?: string
  updateLog?: string
  tinyfishKey?: string
  firecrawlKey?: string
  glossary?: string[]
  about?: string[]
  spellings?: Spellings
  /** Composio Connect key: the user's connected apps become tools. */
  composioKey?: string
  /** Remote MCP servers the user added (headers already filled in from the Keychain). */
  mcpServers?: McpConfig[]
  /** Where MCP header values live (the Keychain), and how the server list (names and URLs only) is saved. */
  secrets?: { get?(account: string): string | undefined; set(account: string, value: string): void; remove(account: string): void }
  saveMcp?: (servers: { name: string; url: string; headerName?: string }[]) => void
  /** Jarvis's own browser. */
  browser?: BrowserLike & SessionBrowser
  /** Whole names that mean the same node, e.g. { "user": "<the user's name>" }, so the user is one node, not several. */
  aliases?: Record<string, string>
  /** Restarts the companion (launchd starts it again), so a key saved from the app is picked up. */
  restart?: () => void
  /** Jarvis Hands: the helper app that uses the Mac's screen, mouse and keyboard (computer use). */
  hands?: HandsCall
  /** Installed skills (folders with a SKILL.md). */
  skills?: SkillStore
  /** Persists what was learned so it survives a restart. */
  onLearned?: (learned: { spellings: Spellings; glossary: string[] }) => void
}

export interface ServerOptions {
  socketPath: string
  db: DatabaseSync
  deps: ServerDeps
  ledgerPath: string
}

/** The keys Jarvis uses, set from the app's Setup panel and kept in the Keychain. Values never leave the companion. */
const KEYS = [
  { name: 'ANTHROPIC_API_KEY', required: true, purpose: 'Answers, memory and meeting notes (Claude)' },
  { name: 'TYPESAFE_API_KEY', required: false, purpose: 'Picks the right Claude model per question; without it every answer uses Sonnet' },
  { name: 'TINYFISH_API_KEY', required: false, purpose: 'Web search' },
  { name: 'FIRECRAWL_API_KEY', required: false, purpose: 'Web search and reading pages (backup)' },
  { name: 'COMPOSIO_API_KEY', required: false, purpose: 'Connected apps: Gmail, Calendar, Slack, Linear and more' },
] as const
const NEEDS_CLAUDE = new Set(['ask', 'research', 'ingest', 'meetingNote', 'importText'])
const NO_KEY = 'Add your Anthropic API key in Settings > Setup first.'
const DEFAULT_SPACES: Context[] = ['company', 'professional']
const PAUSED = 'Cloud processing is paused. Nothing was sent.'
const MAX_INSTRUCTIONS = 10
const MAX_FILES = 10
const LEARN_WAIT_MS = 1500
const IMPORT_CHUNK_CHARS = 2000
const APPROVAL_TIMEOUT_MS = 120_000
const MAX_IMPORT_CHUNKS = 200
const REMIND_CHECK_MS = 10_000

function getSetting(db: DatabaseSync, key: string): string | undefined {
  return (db.prepare('SELECT value FROM settings WHERE key = ?').get(key) as { value: string } | undefined)?.value
}

export async function startServer(opts: ServerOptions): Promise<{ close(): Promise<void> }> {
  const { db, ledgerPath } = opts
  db.exec('CREATE TABLE IF NOT EXISTS settings (key TEXT PRIMARY KEY, value TEXT NOT NULL)')
  const deps: ServerDeps = { ...opts.deps, fetch: ledgered(opts.deps.fetch, ledgerPath) }
  let spellings = opts.deps.spellings ?? {}
  let vocabulary = opts.deps.glossary ?? []
  respellMemory(db, spellings)
  const aliases = opts.deps.aliases ?? {}
  mergeAliases(db, aliases)
  /** Corrected once, fixed for good: future speech, questions and notes, and every note already stored. */
  const learnSpelling = ({ heard, correct }: Spelling): void => {
    spellings = { ...spellings, [heard.toLowerCase()]: correct }
    if (!vocabulary.includes(correct)) vocabulary = [...vocabulary, correct]
    respellMemory(db, { [heard.toLowerCase()]: correct })
    opts.deps.onLearned?.({ spellings, glossary: vocabulary })
  }
  const paused = (): boolean => getSetting(db, 'pauseCloud') === 'true'
  const store = opts.deps.secrets
  const oauth = new McpOAuth({ fetch: deps.fetch, secrets: { get: (k) => store?.get?.(k), set: (k, v) => store?.set(k, v), remove: (k) => store?.remove(k) } })
  /** Your own servers use a sign-in token when they have one; a header key otherwise. */
  const ownServer = (c: McpConfig): McpServer => new McpServer({ ...c, token: () => oauth.token(c.name).catch(() => undefined) }, deps.fetch)
  let mcp: McpServer[] = [
    ...(opts.deps.composioKey ? [composioConnect(opts.deps.composioKey, deps.fetch)] : []),
    ...(opts.deps.mcpServers ?? []).map(ownServer),
  ]

  /** Saves names, addresses and header names only: the header values stay in the Keychain. */
  const saveMcpList = (): void => opts.deps.saveMcp?.(mcp.filter((m) => m.config.name !== 'composio')
    .map((m) => ({ name: m.config.name, url: m.config.url, headerName: Object.keys(m.config.headers)[0] })))

  /** Images for answers: links from what Jarvis read load on their own, anything else waits for a click. */
  const images = new ImageGate(deps.fetch)

  /** What the app's browser window shows, and who is in control of the page. */
  const session = opts.deps.browser ? new BrowserSession(opts.deps.browser) : undefined

  /** Actions waiting for the user's yes or no, by id. */
  const approvals = new Map<string, (ok: boolean) => void>()

  /** Background tasks: long jobs Jarvis hands to a helper with the web and the connected apps (not the browser). */
  // The ledgered fetch, so every call a helper makes is recorded like the chat's.
  const webKeys = deps.tinyfishKey || deps.firecrawlKey ? { fetch: deps.fetch, tinyfishKey: deps.tinyfishKey, firecrawlKey: deps.firecrawlKey } : undefined
  const tasks = new TaskRunner(backgroundWorker({
    llm: { fetch: deps.fetch, apiKey: deps.anthropicKey }, web: webKeys, paused: () => paused(),
    connectors: async (approve) => (mcp.length ? mcpTools(mcp, approve) : undefined),
  }))

  /** Reminders: checked every few seconds. A reminder goes to the app watching (kept for when it is back); a scheduled
   * job starts as a background task, whose report reaches the app like any other. */
  /** Meeting notes: kept apart from the main memory, searched only for meeting questions. */
  const meetings = new MeetingMemory(db)

  const reminders = new Reminders(db)
  const remindWatchers = new Set<(r: Reminder) => void>()
  const remind = (): void => {
    for (const r of reminders.due()) {
      if (r.run) { try { tasks.start(r.text) } catch { continue } } // too many running: try again on the next check
      else if (!remindWatchers.size) continue
      for (const w of remindWatchers) w(r)
      reminders.fired(r.id)
    }
  }
  const clock = setInterval(remind, REMIND_CHECK_MS)
  clock.unref()

  /** Watches the user set up: each checks their connected apps on its own schedule (not while paused). */
  const watches = new Watches(db, reminders, watchChecker(() => mcp, { fetch: deps.fetch, apiKey: deps.anthropicKey }))
  const watchClock = setInterval(() => { if (!paused()) void watches.checkDue() }, WATCH_TICK_MS)
  watchClock.unref()

  /** The tools for one answer: they ask the app before critical steps and show each step in the trace. */
  async function toolsFor(send: (e: Event) => void, id: string, gone: AbortSignal, question: string): Promise<{ kit: ToolKit; guide: string } | undefined> {
    const approve = (action: string): Promise<boolean> => new Promise((resolve) => {
      const approvalId = randomUUID()
      const timer = setTimeout(() => settle(false), APPROVAL_TIMEOUT_MS) // no answer means no
      function settle(ok: boolean): void { if (approvals.delete(approvalId)) { clearTimeout(timer); resolve(ok) } }
      approvals.set(approvalId, settle)
      send({ id, type: 'approval', approvalId, action })
      gone.addEventListener('abort', () => settle(false), { once: true })
    })
    let scrub = (t: string): string => t // the combined kit's scrub, once it exists
    const kits: ToolKit[] = [taskTools(tasks, (t) => scrub(t)), reminderTools(reminders, (t) => scrub(t), approve),
      controlTools((action) => send({ id, type: 'control', action }), question), meetingTools(meetings)]
    const guides: string[] = [TASK_GUIDE, REMINDER_GUIDE, NOTES_GUIDE, MEETINGS_GUIDE]
    if (opts.deps.hands) {
      const hands = opts.deps.hands
      kits.push(computerTools(hands, approve, (jpeg) => send({ id, type: 'screenshot', jpeg })))
      guides.push(COMPUTER_GUIDE)
      gone.addEventListener('abort', () => { void hands('end').catch(() => undefined) }, { once: true }) // interrupted: the border goes
    }
    const skills = opts.deps.skills?.list().filter((s) => s.enabled) ?? []
    if (opts.deps.skills && skills.length) { kits.push(skillTools(opts.deps.skills, approve)); guides.push(SKILLS_GUIDE(skills)) }
    if (mcp.length) { kits.push(watchTools(watches, approve, (t) => scrub(t))); guides.push(WATCH_GUIDE) }
    if (opts.deps.browser) {
      const b = opts.deps.browser
      const visiting: BrowserLike = { read: () => b.read(), click: (l) => b.click(l), type: (f, t) => b.type(f, t), screenshot: () => b.screenshot(),
        check: (l) => b.check(l), checkField: (f) => b.checkField(f),
        open: async (url) => { recordVisit(ledgerPath, url); return b.open(url) } }
      kits.push(browserTools(visiting, approve, (jpeg) => send({ id, type: 'screenshot', jpeg }), question, session && ((reason) => session.askUser(reason))))
      guides.push(BROWSER_GUIDE)
    }
    if (mcp.length) {
      // A connector's own image links (its storage, on its own site) may show without a click; email or page content never.
      const kit = await mcpTools(mcp, approve, (image) => send({ id, type: 'image', ...image }), (serverUrl, text) => images.trustFrom(serverUrl, text))
      if (kit.definitions.length) { kits.push(kit); guides.push(MCP_GUIDE) }
    }
    if (!kits.length) return undefined
    const all = combineTools(kits)
    scrub = all.redact ?? scrub
    const label = (name: string, input: unknown): string => {
      const i = (input ?? {}) as Record<string, unknown>
      if (typeof i.url === 'string') { try { return new URL(i.url).host } catch { return '' } }
      return String(i.action ?? i.label ?? i.query ?? i.field ?? '').slice(0, 60)
    }
    return { kit: { ...all, get definitions() { return all.definitions }, get maxSteps() { return all.maxSteps }, run: async (name, input) => {
      send({ id, type: 'trace', stage: 'tool', name, detail: label(name, input) })
      if (name.startsWith('browser_') && session) {
        session.working() // the app shows the browser window while Jarvis uses it
        // If whoever asked goes away (interrupted, app quit), the browser session and any handover end too.
        gone.addEventListener('abort', () => session.idle(), { once: true })
      }
      return all.run(name, input)
    } }, guide: guides.join('\n\n') }
  }

  /** A file being imported in the background, for the progress line. */
  let importing: { name: string; done: number; total: number; waiting?: number } | null = null
  // Files are imported one after another; more can be sent at once and wait their turn.
  let importQueue: Promise<void> = Promise.resolve()
  let waiting = 0
  /** How the user wants replies, learned from chat ("reply in as few words as possible"). */
  const instructions = (): string[] => JSON.parse(getSetting(db, 'instructions') ?? '[]') as string[]
  const setInstructions = (list: string[]): void => {
    db.prepare('INSERT OR REPLACE INTO settings(key, value) VALUES (?, ?)').run('instructions', JSON.stringify(list.filter((t) => typeof t === 'string' && t.trim()).slice(-MAX_INSTRUCTIONS)))
  }

  async function handle(raw: Request, send: (e: Event) => void, gone: AbortSignal): Promise<void> {
    const req = raw.type === 'ask' ? { ...raw, question: fixSpelling(raw.question, spellings) }
      : raw.type === 'ingest' ? { ...raw, text: fixSpelling(raw.text, spellings) } : raw
    if (NEEDS_CLAUDE.has(req.type) && !deps.anthropicKey) return send({ id: req.id, type: 'error', code: 'setup', message: NO_KEY })
    switch (req.type) {
      case 'setup': {
        const present: Record<string, string | undefined> = { ANTHROPIC_API_KEY: opts.deps.anthropicKey, TYPESAFE_API_KEY: opts.deps.typesafeKey,
          TINYFISH_API_KEY: opts.deps.tinyfishKey, FIRECRAWL_API_KEY: opts.deps.firecrawlKey, COMPOSIO_API_KEY: opts.deps.composioKey }
        return send({ id: req.id, type: 'result', keys: KEYS.map((k) => ({ ...k, set: Boolean(present[k.name]) })) })
      }
      case 'setKey': {
        const key = KEYS.find((k) => k.name === req.name)
        const value = String(req.value ?? '').trim()
        if (!key || value.length > 500 || /\s/.test(value)) return send({ id: req.id, type: 'error', code: 'bad_request', message: 'That is not a key Jarvis uses.' })
        if (!opts.deps.secrets) return send({ id: req.id, type: 'error', code: 'unavailable', message: 'The Keychain is not available.' })
        if (!value) {
          opts.deps.secrets.remove(key.name)
        } else if (key.name === 'ANTHROPIC_API_KEY') {
          // Checked before saving, so a typo is caught here and not on the first question.
          const r = await deps.fetch('https://api.anthropic.com/v1/models', { headers: { 'x-api-key': value, 'anthropic-version': '2023-06-01' } }).catch(() => null)
          if (r && (r.status === 401 || r.status === 403)) return send({ id: req.id, type: 'error', code: 'bad_key', message: 'Anthropic rejected that key. Check it and try again.' })
        }
        if (value) opts.deps.secrets.set(key.name, value)
        send({ id: req.id, type: 'result', ok: true })
        setTimeout(() => opts.deps.restart?.(), 20) // after the reply has gone out
        return
      }
      case 'ask': {
        if (paused()) return send({ id: req.id, type: 'error', code: 'paused', message: PAUSED })
        const llm = { fetch: deps.fetch, apiKey: deps.anthropicKey }
        const lastAnswer = req.history?.findLast((t) => t.role === 'assistant')?.content ?? ''
        // Learns from the chat while it answers: facts, "remember that..." and corrections become notes.
        const learning = learnFromTurn(raw.question, lastAnswer, llm).then(async ({ note, spelling, instruction }) => {
          if (spelling) learnSpelling(spelling)
          if (instruction && !instructions().includes(instruction)) setInstructions([...instructions(), instruction])
          const r = note ? await remember(db, fixSpelling(note, spellings), `chat-${randomUUID()}`, llm, vocabulary, deps.about ?? [], new Date()) : null
          if (r?.kept) mergeAliases(db, aliases)
          return { saved: r?.kept ? { context: r.context, replaced: r.replaced } : undefined, spelling: spelling ?? undefined, instruction: instruction ?? undefined }
        }).catch(() => ({ saved: undefined, spelling: undefined, instruction: undefined }))
        const tools = await toolsFor(send, req.id, gone, req.question)
        const result = await askStream(db, req.question, deps, (text) => send({ id: req.id, type: 'sentence', text }), {
          contexts: req.contexts ?? DEFAULT_SPACES,
          history: req.history,
          summary: typeof req.summary === 'string' ? req.summary : undefined,
          files: Array.isArray(req.files) ? req.files.filter((f) => typeof f?.name === 'string' && typeof f?.data === 'string').slice(0, MAX_FILES) : undefined,
          onToken: (text) => send({ id: req.id, type: 'token', text }),
          onTrace: (step) => send({ id: req.id, type: 'trace', ...step }),
          voice: req.voice === true,
          signal: gone,
          tools: tools?.kit,
          toolGuide: tools?.guide,
          instructions: instructions(),
        })
        // Learning keeps going in the background; the answer only waits a moment for what it learned.
        session?.idle() // the answer is done, so is this browser session
        void deps.hands?.('end').catch(() => undefined) // and any use of the screen: the border goes and the approval ends
        const learned = await Promise.race([learning, new Promise<object>((r) => setTimeout(() => r({}), LEARN_WAIT_MS))])
        return send({ id: req.id, type: 'result', ...result, ...learned })
      }
      case 'research': {
        if (paused()) return send({ id: req.id, type: 'error', code: 'paused', message: PAUSED })
        const r = await research(req.question, { fetch: deps.fetch, anthropicKey: deps.anthropicKey, typesafeKey: deps.typesafeKey, tinyfishKey: deps.tinyfishKey, firecrawlKey: deps.firecrawlKey })
        return send({ id: req.id, type: 'result', ...r })
      }
      case 'ingest': {
        if (paused()) return send({ id: req.id, type: 'error', code: 'paused', message: PAUSED })
        // Spoken and typed notes are anchored to now; imported documents are not, since when they were written is unknown.
        const saidAt = req.clipId.startsWith('import:') ? undefined : new Date()
        const r = await remember(db, req.text, req.clipId, { fetch: deps.fetch, apiKey: deps.anthropicKey }, vocabulary, deps.about ?? [], saidAt)
        if (r.kept) mergeAliases(db, aliases)
        return send({ id: req.id, type: 'result', ...r })
      }
      case 'meetingNote': {
        if (paused()) return send({ id: req.id, type: 'error', code: 'paused', message: PAUSED })
        const lines = (Array.isArray(req.lines) ? req.lines : []) as TranscriptLine[]
        const note = await writeMeetingNote(lines, String(req.started ?? ''), { fetch: deps.fetch, apiKey: deps.anthropicKey })
        // Kept in the meeting store, never in the main memory: other people's words cannot change what the user told Jarvis.
        meetings.save({ id: String(req.meetingId ?? ''), title: note.title, started: String(req.started ?? ''), note: note.markdown })
        return send({ id: req.id, type: 'result', title: note.title, note: note.markdown, kept: true })
      }
      case 'graph':
        return send({ id: req.id, type: 'result', ...graphWithDetails(db, req.contexts) })
      case 'notes':
        return send({ id: req.id, type: 'result', notes: listNotes(db, req.contexts ?? DEFAULT_SPACES, Math.min(req.limit ?? 200, 1000)) })
      case 'todos':
        return send({ id: req.id, type: 'result', todos: listTodos(db, req.contexts ?? DEFAULT_SPACES) })
      case 'todo':
        if (!TODO_STATUSES.includes(req.status)) return send({ id: req.id, type: 'error', code: 'bad_request', message: 'status must be open, done or dropped' })
        setTodoStatus(db, Number(req.todoId), req.status)
        return send({ id: req.id, type: 'result', ok: true })
      case 'importText': {
        if (paused()) return send({ id: req.id, type: 'error', code: 'paused', message: PAUSED })
        const name = String(req.name ?? 'file').replace(/[^\p{L}\p{N} ._-]/gu, '').slice(0, 80) || 'file'
        const seen = db.prepare('SELECT 1 FROM segments WHERE clip = ? UNION SELECT 1 FROM discarded WHERE clip = ?')
        const chunks = chunkMarkdown(String(req.text ?? ''), name, IMPORT_CHUNK_CHARS)
          .map((c, i) => ({ text: c.text, clip: `import:${name}#${i + 1}` })).filter((c) => !seen.get(c.clip, c.clip))
        // Each part is one model call: cap it, so one file can never run up a large bill.
        if (chunks.length > MAX_IMPORT_CHUNKS) return send({ id: req.id, type: 'error', code: 'too_large', message: `That file is too big to import at once (${chunks.length} parts, limit ${MAX_IMPORT_CHUNKS}). Split it into smaller files.` })
        send({ id: req.id, type: 'result', chunks: chunks.length })
        if (!chunks.length) return
        const llm = { fetch: deps.fetch, apiKey: deps.anthropicKey }
        waiting++
        if (!importing) importing = { name, done: 0, total: chunks.length, waiting: waiting - 1 }
        importQueue = importQueue.then(async () => {
          waiting--
          importing = { name, done: 0, total: chunks.length, waiting }
          for (const c of chunks) {
            if (paused()) break // pausing stops queued imports too
            if (seen.get(c.clip, c.clip)) continue // the same file sent twice is imported once
            await remember(db, fixSpelling(c.text, spellings), c.clip, llm, vocabulary, deps.about ?? []).catch(() => null)
            importing = { ...importing!, done: importing!.done + 1, waiting }
          }
          mergeAliases(db, aliases)
        }).catch(() => {}).finally(() => { if (!waiting) importing = null })
        return
      }
      case 'approve': {
        const settle = approvals.get(String(req.approvalId))
        settle?.(req.ok === true)
        const known = Boolean(settle) || tasks.answer(String(req.approvalId), req.ok === true) // or a background task's
        return send({ id: req.id, type: 'result', ok: known })
      }
      case 'connectors': {
        // Each MCP server and how many tools it offers; a server that is down shows 0.
        const servers = await Promise.all(mcp.filter((m) => m.config.name !== 'composio').map(async (m) => {
          try { return { name: m.config.name, tools: (await m.tools()).length, url: m.config.url, needsSignIn: false } }
          catch (e) { return { name: m.config.name, tools: 0, url: m.config.url, needsSignIn: e instanceof NeedsSignIn } }
        }))
        return send({ id: req.id, type: 'result', servers })
      }
      case 'apps': {
        // Your choice in Settings, so no approval: listing, connecting and removing accounts.
        const composio = mcp.find((m) => m.config.name === 'composio')
        if (!composio) return send({ id: req.id, type: 'result', available: false, apps: [] })
        return send({ id: req.id, type: 'result', available: true, apps: await listApps(composio) })
      }
      case 'connectApp': {
        const composio = mcp.find((m) => m.config.name === 'composio')
        if (!composio) return send({ id: req.id, type: 'error', code: 'no_key', message: 'Add a Composio key first.' })
        return send({ id: req.id, type: 'result', url: await connectApp(composio, String(req.toolkit), req.alias) })
      }
      case 'removeApp': {
        const composio = mcp.find((m) => m.config.name === 'composio')
        if (!composio) return send({ id: req.id, type: 'error', code: 'no_key', message: 'Add a Composio key first.' })
        await removeApp(composio, String(req.toolkit), String(req.accountId))
        return send({ id: req.id, type: 'result', ok: true })
      }
      case 'renameApp': {
        const composio = mcp.find((m) => m.config.name === 'composio')
        if (!composio) return send({ id: req.id, type: 'error', code: 'no_key', message: 'Add a Composio key first.' })
        await renameApp(composio, String(req.toolkit), String(req.accountId), String(req.alias ?? ''))
        return send({ id: req.id, type: 'result', ok: true })
      }
      // Skills: your choice in Settings, so no approval for installing or changing them (their commands still ask).
      case 'skills':
        return send({ id: req.id, type: 'result', skills: opts.deps.skills?.list() ?? [] })
      case 'installSkill': {
        if (!opts.deps.skills) return send({ id: req.id, type: 'error', code: 'unavailable', message: 'Skills are not available.' })
        return send({ id: req.id, type: 'result', installed: await installSkill(opts.deps.skills, String(req.source ?? '')) })
      }
      case 'setSkill':
        opts.deps.skills?.update(String(req.name), { ...(typeof req.enabled === 'boolean' ? { enabled: req.enabled } : {}), ...(typeof req.autoRun === 'boolean' ? { autoRun: req.autoRun } : {}) })
        return send({ id: req.id, type: 'result', ok: true })
      case 'removeSkill':
        opts.deps.skills?.remove(String(req.name))
        return send({ id: req.id, type: 'result', ok: true })
      case 'addMcp': {
        const name = String(req.name ?? '').trim()
        let url: URL
        try { url = new URL(String(req.url)) } catch { return send({ id: req.id, type: 'error', code: 'bad_request', message: 'That is not a web address.' }) }
        if (url.protocol !== 'https:' || !/^[\w.-]{1,40}$/.test(name) || name === 'composio' || mcp.some((m) => m.config.name === name))
          return send({ id: req.id, type: 'error', code: 'bad_request', message: 'Use a short unique name and an https address.' })
        const headerName = req.headerName ? String(req.headerName).trim() : undefined
        if (headerName && !/^[A-Za-z0-9-]{1,60}$/.test(headerName)) return send({ id: req.id, type: 'error', code: 'bad_request', message: 'That header name is not valid.' })
        if (headerName && req.headerValue) opts.deps.secrets?.set(`mcp:${name}`, String(req.headerValue))
        mcp = [...mcp, ownServer({ name, url: url.href, headers: headerName && req.headerValue ? { [headerName]: String(req.headerValue) } : {} })]
        saveMcpList()
        return send({ id: req.id, type: 'result', ok: true })
      }
      case 'image':
        return send({ id: req.id, type: 'result', ...(await images.load(String(req.url), req.clicked === true)) })
      case 'watchTasks': {
        // A long-lived stream: every background task as it changes, and the approvals they ask for.
        const stop = tasks.watch((e) => send(e.kind === 'task' ? { id: req.id, type: 'task', ...e.task } : { id: req.id, type: 'approval', approvalId: e.approvalId, action: `Background task: ${e.action}` }))
        // Reminders come on the same stream; any that went off while the app was away arrive now.
        const onReminder = (r: Reminder): void => send({ id: req.id, type: 'reminder', reminderId: r.id, text: r.text, run: r.run })
        remindWatchers.add(onReminder)
        gone.addEventListener('abort', () => { stop(); remindWatchers.delete(onReminder) }, { once: true })
        remind()
        return
      }
      case 'cancelTask':
        return send({ id: req.id, type: 'result', ok: tasks.cancel(String(req.taskId)) })
      case 'reminder': {
        const rid = Number(req.reminderId)
        if (req.action === 'snooze') { reminders.snooze(rid, Number(req.minutes ?? 10)); return send({ id: req.id, type: 'result', ok: true }) }
        if (req.action === 'cancel') return send({ id: req.id, type: 'result', ok: reminders.cancel(rid) })
        return send({ id: req.id, type: 'error', code: 'bad_request', message: 'action must be snooze or cancel' })
      }
      case 'watchBrowser': {
        // A long-lived stream for the app's browser window: state changes and frames, until the app goes away.
        if (!session) return send({ id: req.id, type: 'error', code: 'no_browser', message: 'No browser available.' })
        const stop = session.watch((e) => send({ id: req.id, type: 'browser', ...e }))
        gone.addEventListener('abort', stop, { once: true })
        return
      }
      case 'browserInput': {
        if (!session) return send({ id: req.id, type: 'error', code: 'no_browser', message: 'No browser available.' })
        try { await session.input(req.input) } catch (e) { return send({ id: req.id, type: 'error', code: 'not_now', message: e instanceof Error ? e.message : 'not now' }) }
        return send({ id: req.id, type: 'result', ok: true })
      }
      case 'browserResume':
        session?.resume(String(req.note ?? ''))
        return send({ id: req.id, type: 'result', ok: true })
      case 'mcpSignIn': {
        // Opens the server's own login page; when the browser comes back, the server reconnects with the new token.
        const server = mcp.find((m) => m.config.name === String(req.name) && m.config.name !== 'composio')
        if (!server) return send({ id: req.id, type: 'error', code: 'bad_request', message: 'No server with that name.' })
        const { url, done } = await oauth.signIn(server.config.name, server.config.url)
        done.then(() => server.reset(), () => {})
        return send({ id: req.id, type: 'result', url })
      }
      case 'removeMcp': {
        const name = String(req.name ?? '')
        if (name === 'composio') return send({ id: req.id, type: 'error', code: 'bad_request', message: 'Composio is set up from its key.' })
        mcp = mcp.filter((m) => m.config.name !== name)
        opts.deps.secrets?.remove(`mcp:${name}`)
        oauth.forget(name)
        saveMcpList()
        return send({ id: req.id, type: 'result', ok: true })
      }
      case 'restore':
        restoreNote(db, Number(req.segmentId))
        return send({ id: req.id, type: 'result', ok: true })
      case 'forgetMeeting':
        meetings.forget(String(req.meetingId ?? ''))
        return send({ id: req.id, type: 'result', ok: true })
      case 'forget':
        deleteSegment(db, req.segmentId)
        return send({ id: req.id, type: 'result', ok: true })
      case 'ledger':
        return send({ id: req.id, type: 'result', rows: readLedger(ledgerPath, req.limit ?? 50) })
      case 'update':
        // Installs the staged version; the app quits and reopens, and this companion restarts at the end.
        if (!deps.appHome || !applyUpdate(deps.appHome, deps.updateLog ?? '/dev/null')) return send({ id: req.id, type: 'error', code: 'no_update', message: 'No update is ready.' })
        return send({ id: req.id, type: 'result', ok: true })
      case 'status': {
        const counts = db.prepare('SELECT (SELECT count(*) FROM segments) AS segments, (SELECT count(*) FROM entities) AS entities').get()
        return send({ id: req.id, type: 'result', ok: true, pauseCloud: paused(), counts, vocabulary, spellings, instructions: instructions(), importing,
          ...(deps.appHome ? { update: updateStatus(deps.appHome) } : {}),
          lastCleanup: db.prepare('SELECT at, notes_merged AS notesMerged, entities_merged AS entitiesMerged FROM consolidation_runs ORDER BY id DESC LIMIT 1').get() ?? null })
      }
      case 'feedback': {
        // Rated answers become a local test set for checking later changes. Nothing is sent anywhere.
        if (req.rating !== 'up' && req.rating !== 'down') return send({ id: req.id, type: 'error', code: 'bad_request', message: 'rating must be up or down' })
        db.prepare('INSERT INTO feedback(rating, question, answer, model) VALUES (?, ?, ?, ?)').run(req.rating, String(req.question ?? ''), String(req.answer ?? ''), String(req.model ?? ''))
        return send({ id: req.id, type: 'result', ok: true })
      }
      case 'settings':
        if (req.pauseCloud !== undefined) db.prepare('INSERT OR REPLACE INTO settings(key, value) VALUES (?, ?)').run('pauseCloud', String(req.pauseCloud))
        if (req.pauseCloud === true) for (const t of tasks.list()) if (t.status === 'running') tasks.cancel(t.id) // pausing stops background work too
        if (Array.isArray(req.instructions)) setInstructions(req.instructions)
        return send({ id: req.id, type: 'result', ok: true, pauseCloud: paused() })
      default:
        // Always answer, so a caller never waits forever on a request this version does not know.
        return send({ id: (req as { id: string }).id, type: 'error', code: 'unknown_request', message: 'unknown request type' })
    }
  }

  const open = new Set<net.Socket>()
  const server = net.createServer((socket) => {
    open.add(socket)
    socket.on('close', () => open.delete(socket))
    let buffer = ''
    const send = (e: Event): void => { if (!socket.destroyed) socket.write(encode(e)) }
    socket.on('error', () => {})
    const leaving = new AbortController()
    socket.on('close', () => leaving.abort()) // the app left (for example, you interrupted): stop work for it
    socket.setEncoding('utf8') // decodes across chunk boundaries, so a character split between chunks survives
    let pendingBytes = 0
    socket.on('data', (chunk: string) => {
      // Most of a big request (attached files) arrives without a line end: just collect it, counting bytes as it comes.
      pendingBytes += Buffer.byteLength(chunk)
      if (pendingBytes > MAX_LINE_BYTES) {
        socket.end(encode({ id: '', type: 'error', code: 'too_large', message: 'That is too much to send at once. Attach fewer or smaller files.' }))
        buffer = ''; return
      }
      if (!chunk.includes('\n')) { buffer += chunk; return }
      let decoded
      try { decoded = decodeLines(buffer + chunk) } catch { socket.destroy(); return }
      buffer = decoded.rest
      pendingBytes = Buffer.byteLength(buffer)
      for (const message of decoded.messages as Request[]) {
        handle(message, send, leaving.signal).catch((error: unknown) => {
          send({ id: message.id, type: 'error', code: 'failed', message: error instanceof Error ? error.message : 'request failed' })
        })
      }
    })
  })

  rmSync(opts.socketPath, { force: true })
  await new Promise<void>((resolve, reject) => { server.once('error', reject); server.listen(opts.socketPath, resolve) })
  chmodSync(opts.socketPath, 0o600)
  // Closing also ends open connections, such as the app's long-lived browser watch.
  return { close: () => new Promise((resolve) => { clearInterval(clock); clearInterval(watchClock); server.close(() => resolve()); for (const sock of open) sock.destroy() }) }
}
