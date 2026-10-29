import { test } from 'node:test'
import assert from 'node:assert/strict'
import { TaskRunner, type TaskEvent, type Worker } from './tasks.ts'

const until = async (check: () => boolean): Promise<void> => { for (let i = 0; i < 100 && !check(); i++) await new Promise((r) => setTimeout(r, 5)) }

test('a task runs in the background, reports its steps, and finishes with its report', async () => {
  const work: Worker = async (goal, ctx) => { ctx.step(); ctx.step(); return `Report on ${goal}` }
  const runner = new TaskRunner(work)
  const events: TaskEvent[] = []
  runner.watch((e) => events.push(e))
  const t = runner.start('pricing of three CRMs')
  assert.equal(t.status, 'running')
  await until(() => runner.list()[0].status === 'done')
  const done = runner.list()[0]
  assert.equal(done.result, 'Report on pricing of three CRMs')
  assert.equal(done.steps, 2)
  assert.ok(events.some((e) => e.kind === 'task' && e.task.status === 'done'))
})

test('only a few run at once; more are refused with a reason', () => {
  const runner = new TaskRunner(() => new Promise(() => {}), { max: 2 })
  runner.start('a'); runner.start('b')
  assert.throws(() => runner.start('c'), /already running/)
})

test('cancelling stops the work', async () => {
  let aborted = false
  const runner = new TaskRunner((_, ctx) => new Promise((_, reject) => ctx.signal.addEventListener('abort', () => { aborted = true; reject(new Error('stopped')) })))
  const t = runner.start('long job')
  assert.equal(runner.cancel(t.id), true)
  await until(() => aborted)
  assert.equal(runner.list()[0].status, 'cancelled')
})

test('a failure is reported, not thrown', async () => {
  const runner = new TaskRunner(async () => { throw new Error('no network') })
  runner.start('x')
  await until(() => runner.list()[0].status === 'failed')
  assert.match(runner.list()[0].result!, /no network/)
})

test('approvals go to whoever watches; with nobody watching the answer is no', async () => {
  const answers: boolean[] = []
  const runner = new TaskRunner(async (_, ctx) => { answers.push(await ctx.approve('Send the summary email')); return 'ok' })
  const asked: TaskEvent[] = []
  const stop = runner.watch((e) => { if (e.kind === 'approval') { asked.push(e); runner.answer(e.approvalId, true) } })
  runner.start('one')
  await until(() => answers.length === 1)
  assert.deepEqual(answers, [true])
  assert.equal((asked[0] as { action: string }).action, 'Send the summary email')
  stop()
  runner.start('two')
  await until(() => answers.length === 2)
  assert.deepEqual(answers, [true, false])
})

test('a cancelled task cannot ask for approval, and an app that reconnects sees requests still waiting', async () => {
  const runner = new TaskRunner(async (_, ctx) => { await new Promise((r) => setTimeout(r, 5)); return String(await ctx.approve('send')) })
  const asked: string[] = []
  runner.watch((e) => { if (e.kind === 'approval') asked.push(e.approvalId) })
  const t = runner.start('one')
  await until(() => asked.length === 1)
  const later: TaskEvent[] = []
  runner.watch((e) => later.push(e))
  assert.ok(later.some((e) => e.kind === 'approval'), 'the waiting request is shown again')
  const aborted = new AbortController(); aborted.abort()
  const r2 = new TaskRunner(async (_, ctx) => { await new Promise((r) => setTimeout(r, 5)); return String(await ctx.approve('x')) })
  let prompts = 0
  r2.watch((e) => { if (e.kind === 'approval') prompts++ })
  r2.cancel(r2.start('two').id)
  await until(() => r2.list()[0].status !== 'running')
  assert.equal(prompts, 0)
  void t
})
