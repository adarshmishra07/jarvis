import { randomUUID } from 'node:crypto'

// Background tasks: Jarvis hands a long job (research, going through many emails) to a helper agent and the chat stays
// free. The app watches the tasks, shows them, answers their approvals, and puts each report in the chat when done.

export type TaskStatus = 'running' | 'done' | 'failed' | 'cancelled'
export interface BgTask { id: string; goal: string; status: TaskStatus; startedAt: string; steps: number; result?: string }
export type TaskEvent = { kind: 'task'; task: BgTask } | { kind: 'approval'; approvalId: string; action: string; taskId: string }

export interface WorkContext { signal: AbortSignal; step: () => void; approve: (action: string) => Promise<boolean> }
export type Worker = (goal: string, ctx: WorkContext) => Promise<string>

const DEFAULT_MAX = 2
const APPROVAL_TIMEOUT_MS = 10 * 60_000
const KEEP_FINISHED = 20
const MAX_GOAL_CHARS = 2000

export class TaskRunner {
  private readonly tasks = new Map<string, BgTask & { stop: AbortController }>()
  private readonly watchers = new Set<(e: TaskEvent) => void>()
  private readonly approvals = new Map<string, { settle: (ok: boolean) => void; action: string; taskId: string }>()
  private readonly work: Worker
  private readonly max: number

  constructor(work: Worker, opts: { max?: number } = {}) { this.work = work; this.max = opts.max ?? DEFAULT_MAX }

  private emit(e: TaskEvent): void { for (const w of this.watchers) w(e) }
  private view({ stop: _stop, ...task }: BgTask & { stop: AbortController }): BgTask { return { ...task } }
  private update(id: string, change: Partial<BgTask>): void {
    const t = this.tasks.get(id)
    if (!t || t.status !== 'running') return
    Object.assign(t, change)
    this.emit({ kind: 'task', task: this.view(t) })
  }

  start(goal: string): BgTask {
    if (this.list().filter((t) => t.status === 'running').length >= this.max) throw new Error(`${this.max} background tasks are already running; wait for one to finish`)
    const id = randomUUID().slice(0, 8)
    const task = { id, goal: goal.trim().slice(0, MAX_GOAL_CHARS), status: 'running' as const, startedAt: new Date().toISOString(), steps: 0, stop: new AbortController() }
    this.tasks.set(id, task)
    this.forget()
    this.emit({ kind: 'task', task: this.view(task) })
    const ctx: WorkContext = { signal: task.stop.signal, step: () => this.update(id, { steps: task.steps + 1 }), approve: (action) => this.ask(id, action, task.stop.signal) }
    this.work(task.goal, ctx).then(
      (result) => this.update(id, { status: 'done', result }),
      (e) => this.update(id, task.stop.signal.aborted ? { status: 'cancelled' } : { status: 'failed', result: e instanceof Error ? e.message : 'it stopped unexpectedly' }),
    )
    return this.view(task)
  }

  cancel(id: string): boolean {
    const t = this.tasks.get(id)
    if (!t || t.status !== 'running') return false
    this.update(id, { status: 'cancelled' })
    t.stop.abort()
    return true
  }

  list(): BgTask[] { return [...this.tasks.values()].map((t) => this.view(t)) }

  /** Starts receiving events, beginning with every task as it is now. Returns a function that stops them. */
  watch(fn: (e: TaskEvent) => void): () => void {
    this.watchers.add(fn)
    for (const t of this.list()) fn({ kind: 'task', task: t })
    // Requests still waiting are shown again, so an app that reconnects can answer them.
    for (const [approvalId, a] of this.approvals) fn({ kind: 'approval', approvalId, action: a.action, taskId: a.taskId })
    return () => { this.watchers.delete(fn) }
  }

  answer(approvalId: string, ok: boolean): boolean {
    const pending = this.approvals.get(approvalId)
    pending?.settle(ok)
    return Boolean(pending)
  }

  /** Asks the user through whoever watches. Nobody watching, no answer in time, or a cancelled task all mean no. */
  private ask(taskId: string, action: string, signal: AbortSignal): Promise<boolean> {
    if (!this.watchers.size || signal.aborted) return Promise.resolve(false)
    return new Promise((resolve) => {
      const approvalId = randomUUID()
      const timer = setTimeout(() => settle(false), APPROVAL_TIMEOUT_MS)
      timer.unref()
      const settle = (ok: boolean): void => { if (this.approvals.delete(approvalId)) { clearTimeout(timer); resolve(ok) } }
      this.approvals.set(approvalId, { settle, action, taskId })
      signal.addEventListener('abort', () => settle(false), { once: true })
      this.emit({ kind: 'approval', approvalId, action, taskId })
    })
  }

  /** Finished tasks are kept a while for the list, then dropped. */
  private forget(): void {
    const finished = [...this.tasks.values()].filter((t) => t.status !== 'running')
    for (const t of finished.slice(0, Math.max(0, finished.length - KEEP_FINISHED))) this.tasks.delete(t.id)
  }
}
