import { test } from 'node:test'
import assert from 'node:assert/strict'
import net from 'node:net'
import { mkdtempSync, readFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { openDb, insertExtraction } from './db.ts'
import { startServer } from './server.ts'
import { Reminders } from './reminders.ts'
import { encode, decodeLines } from './protocol.ts'

const note = { keep: true, reason: 'r', sensitivity: 'none', context: 'company' as const, summary: 'Zentro launch is on Friday.', entities: [{ name: 'Zentro', type: 'project' }], edges: [], action_items: [] }

function fakeFetch(calls: string[]): typeof fetch {
  return (async (url: string, init: RequestInit = {}) => {
    calls.push(String(url))
    const body = init.body ? JSON.parse(String(init.body)) : {}
    if (String(url).startsWith('https://api.typesafe.ai')) {
      return new Response(JSON.stringify({ answers: { tier: { type: 'choice', choice: 'fast', confidence: 0.9, probabilities: { fast: 0.9 } }, effort: { type: 'score', score: 0 }, risky: { type: 'noul', noul: 0 } } }), { status: 200 })
    }
    if (body.stream) {
      const sse = (t: string) => `event: content_block_delta\ndata: ${JSON.stringify({ type: 'content_block_delta', delta: { type: 'text_delta', text: t } })}\n\n`
      return new Response(sse('Friday [1]. ') + sse('It is Zentro.'), { status: 200 })
    }
    const system = String(body.system ?? '')
    const said = String(body.messages?.[0]?.content ?? '')
    const json = system.includes('You decide whether') ? { note: said.includes('Remember that') ? 'Asha leads Atlas.' : null, spelling: said.includes('not zentra') ? { heard: 'zentra', correct: 'Zentro' } : null,
        instruction: said.includes('Always reply') ? 'Always reply short.' : null }
      : system.includes('memory facts') ? { ...note, summary: 'Asha leads Atlas', entities: [{ name: 'Asha', type: 'person' }] }
      : {}
    return new Response(JSON.stringify({ content: [{ type: 'text', text: JSON.stringify(json) }] }), { status: 200 })
  }) as unknown as typeof fetch
}

async function setup(calls: string[] = [], spellings: Record<string, string> = {}, slowMs = 0) {
  const dir = mkdtempSync(join(tmpdir(), 'pika-'))
  const db = openDb(':memory:')
  const ledgerPath = join(dir, 'ledger.jsonl')
  const socketPath = join(dir, 's.sock')
  const server = await startServer({ socketPath, db, ledgerPath, deps: { fetch: slowMs ? (async (u: string, i?: RequestInit) => { await new Promise((r) => setTimeout(r, slowMs)); return fakeFetch(calls)(u, i) }) as typeof fetch : fakeFetch(calls), anthropicKey: 'ak', typesafeKey: 'tk', spellings } })
  const call = (req: object): Promise<any[]> => new Promise((resolve, reject) => {
    const events: any[] = []
    let buf = ''
    const c = net.createConnection(socketPath, () => c.write(encode(req as never)))
    c.on('data', (d) => {
      const r = decodeLines(buf + d.toString('utf8')); buf = r.rest
      for (const m of r.messages as any[]) { events.push(m); if (m.type === 'result' || m.type === 'error') { c.end(); resolve(events) } }
    })
    c.on('error', reject)
  })
  return { db, server, call, ledgerPath, socketPath }
}

test('ask streams sentences then a result with numbered citations', async () => {
  const calls: string[] = []
  const { db, server, call } = await setup(calls)
  insertExtraction(db, 'clip-1', 'Zentro launch is on Friday.', note)
  const events = await call({ id: 'a', type: 'ask', question: 'When is the Zentro launch?' })
  assert.ok(events.some((e) => e.type === 'sentence'))
  const last = events.at(-1)
  assert.equal(last.type, 'result')
  assert.deepEqual(last.citations, ['clip-1'])
  await server.close()
})

test('ask streams raw tokens for the screen as well as sentences for speech', async () => {
  const { db, server, call } = await setup()
  insertExtraction(db, 'clip-1', 'Zentro launch is on Friday.', note)
  const events = await call({ id: 'a', type: 'ask', question: 'When is the Zentro launch?' })
  assert.equal(events.filter((e) => e.type === 'token').map((e) => e.text).join(''), 'Friday [1]. It is Zentro.')
  await server.close()
})

test('a fact said in chat is saved to memory and the result says where', async () => {
  const { db, server, call } = await setup()
  const r = (await call({ id: 'a', type: 'ask', question: 'Remember that Asha leads Atlas' })).at(-1)
  assert.deepEqual(r.saved, { context: 'company', replaced: 0 })
  assert.equal((db.prepare('SELECT count(*) AS n FROM segments').get() as { n: number }).n, 1)
  const q = (await call({ id: 'b', type: 'ask', question: 'Who leads Atlas?' })).at(-1)
  assert.equal(q.saved, undefined)
  assert.equal((db.prepare('SELECT count(*) AS n FROM segments').get() as { n: number }).n, 1)
  await server.close()
})

test('ingest reports the space and how many older notes it replaced', async () => {
  const { server, call } = await setup()
  const r = (await call({ id: 'i', type: 'ingest', text: 'Asha leads Atlas.', clipId: 'note-1' })).at(-1)
  assert.deepEqual({ kept: r.kept, context: r.context, replaced: r.replaced }, { kept: true, context: 'company', replaced: 0 })
  await server.close()
})

test('spelling fixes apply to questions, new notes and stored notes', async () => {
  const calls: string[] = []
  const { db, server, call } = await setup(calls, { zentra: 'Zentro' })
  insertExtraction(db, 'clip-1', 'Zentro launch is on Friday.', note)
  const r = (await call({ id: 'a', type: 'ask', question: 'When is the zentra launch?' })).at(-1)
  assert.deepEqual(r.citations, ['clip-1'], 'the fixed question finds the Zentro note')
  await call({ id: 'i', type: 'ingest', text: 'Remember the zentra demo.', clipId: 'note-1' })
  assert.equal((db.prepare("SELECT text FROM segments WHERE clip = 'note-1'").get() as { text: string }).text, 'Remember the Zentro demo.')
  await server.close()
})

test('a spelling corrected once is learned and fixes stored notes and later questions', async () => {
  const { db, server, call } = await setup()
  insertExtraction(db, 'clip-1', 'The zentra launch is on Friday.', note)
  const r = (await call({ id: 'a', type: 'ask', question: 'It is always Zentro, not zentra' })).at(-1)
  assert.deepEqual(r.spelling, { heard: 'zentra', correct: 'Zentro' })
  assert.equal((db.prepare("SELECT text FROM segments WHERE clip = 'clip-1'").get() as { text: string }).text, 'The Zentro launch is on Friday.')
  const status = (await call({ id: 's', type: 'status' })).at(-1)
  assert.deepEqual(status.spellings, { zentra: 'Zentro' })
  assert.ok(status.vocabulary.includes('Zentro'))
  await server.close()
})

test('ask streams trace steps before the answer for the live view', async () => {
  const { db, server, call } = await setup()
  insertExtraction(db, 'clip-1', 'Zentro launch is on Friday.', note)
  const events = await call({ id: 'a', type: 'ask', question: 'When is the Zentro launch?' })
  const stages = events.filter((e) => e.type === 'trace').map((e) => e.stage)
  assert.deepEqual(stages, ['memory', 'answer'])
  assert.ok(events.findIndex((e) => e.type === 'trace') < events.findIndex((e) => e.type === 'token'))
  await server.close()
})

test('feedback on an answer is stored locally as a test case, and nothing is sent anywhere', async () => {
  const calls: string[] = []
  const { db, server, call } = await setup(calls)
  const r = (await call({ id: 'f', type: 'feedback', rating: 'down', question: 'When is the Orbit launch?', answer: 'Friday.', model: 'claude-haiku-5-5' })).at(-1)
  assert.equal(r.type, 'result')
  const row = db.prepare('SELECT rating, question, answer, model FROM feedback').get() as Record<string, string>
  assert.deepEqual({ ...row }, { rating: 'down', question: 'When is the Orbit launch?', answer: 'Friday.', model: 'claude-haiku-5-5' })
  const bad = (await call({ id: 'g', type: 'feedback', rating: 'meh', question: 'x', answer: 'y' })).at(-1)
  assert.equal(bad.type, 'error')
  assert.equal(calls.length, 0)
  await server.close()
})

test('an unknown request gets an error instead of hanging', async () => {
  const { server, call } = await setup()
  assert.equal((await call({ id: 'u', type: 'teleport' })).at(-1).code, 'unknown_request')
  await server.close()
})

test('a standing instruction is kept, used in every later answer, listed in status, and can be removed', async (t) => {
  const systems: string[] = []
  const base = fakeFetch([])
  const spy = (async (url: string, init: RequestInit = {}) => {
    const body = init.body ? JSON.parse(String(init.body)) : {}
    if (body.stream) systems.push(String(body.system))
    return base(url, init)
  }) as unknown as typeof fetch
  const dir = mkdtempSync(join(tmpdir(), 'pika-'))
  const db = openDb(':memory:')
  const socketPath = join(dir, 's.sock')
  const server = await startServer({ socketPath, db, ledgerPath: join(dir, 'l.jsonl'), deps: { fetch: spy, anthropicKey: 'ak', typesafeKey: 'tk' } })
  t.after(() => server.close()) // closes even when an assertion fails, so the run never hangs
  const call = (req: object): Promise<any> => new Promise((resolve) => {
    let buf = ''
    const c = net.createConnection(socketPath, () => c.write(encode(req as never)))
    c.on('data', (d) => { buf += d; for (const l of buf.split('\n')) { if (!l) continue; const m = JSON.parse(l); if (m.type === 'result' || m.type === 'error') { c.end(); resolve(m) } } })
  })
  const r = await call({ id: 'a', type: 'ask', question: 'Always reply short please' })
  assert.equal(r.instruction, 'Always reply short please')
  await call({ id: 'b', type: 'ask', question: 'Tell me about Atlas', voice: true })
  assert.ok(systems.at(-1)!.includes('Always reply short please') && /spoken conversation/i.test(systems.at(-1)!))
  assert.deepEqual((await call({ id: 's', type: 'status' })).instructions, ['Always reply short please'])
  await call({ id: 'x', type: 'settings', instructions: [] })
  await call({ id: 'c', type: 'ask', question: 'Tell me about Atlas' })
  assert.ok(!systems.at(-1)!.includes('Always reply short please'))
})

test('text split mid-character across socket chunks arrives intact', async () => {
  const dir = mkdtempSync(join(tmpdir(), 'pika-'))
  const db = openDb(':memory:')
  const socketPath = join(dir, 's.sock')
  const server = await startServer({ socketPath, db, ledgerPath: join(dir, 'l.jsonl'), deps: { fetch: fakeFetch([]), anthropicKey: 'ak', typesafeKey: 'tk' } })
  const text = 'कल prod पे deploy करना है'
  const bytes = Buffer.from(encode({ id: 'i', type: 'ingest', text, clipId: 'hi-1' } as never))
  const cut = bytes.indexOf(Buffer.from('क')) + 1 // inside a three-byte character
  await new Promise<void>((resolve) => {
    const c = net.createConnection(socketPath, () => { c.write(bytes.subarray(0, cut)); setTimeout(() => c.write(bytes.subarray(cut)), 30) })
    c.on('data', () => { c.end(); resolve() })
  })
  assert.equal((db.prepare("SELECT text FROM segments WHERE clip = 'hi-1'").get() as { text: string }).text, text)
  await server.close()
})

test('slow learning never holds back the answer, and leaving mid-answer stops the model', async (t) => {
  let streamSignal: AbortSignal | undefined
  const base = fakeFetch([])
  const slow = (async (url: string, init: RequestInit = {}) => {
    const body = init.body ? JSON.parse(String(init.body)) : {}
    if (String(body.system ?? '').includes('You decide whether')) await new Promise((r) => setTimeout(r, 4000))
    if (body.stream && JSON.stringify(body.messages).includes('forever')) {
      streamSignal = init.signal ?? undefined
      return new Response(new ReadableStream({ start() {} }), { status: 200 }) // never ends
    }
    return base(url, init)
  }) as unknown as typeof fetch
  const dir = mkdtempSync(join(tmpdir(), 'pika-'))
  const socketPath = join(dir, 's.sock')
  const server = await startServer({ socketPath, db: openDb(':memory:'), ledgerPath: join(dir, 'l.jsonl'), deps: { fetch: slow, anthropicKey: 'ak', typesafeKey: 'tk' } })
  t.after(() => server.close())
  const started = performance.now()
  await new Promise<void>((resolve) => {
    let buf = ''
    const c = net.createConnection(socketPath, () => c.write(encode({ id: 'a', type: 'ask', question: 'Tell me about Atlas' } as never)))
    c.setEncoding('utf8')
    c.on('data', (d: string) => { buf += d; if (buf.includes('"type":"result"')) { c.end(); resolve() } })
  })
  assert.ok(performance.now() - started < 2500, 'result did not wait 4 s for learning')

  const c = net.createConnection(socketPath, () => c.write(encode({ id: 'b', type: 'ask', question: 'talk forever' } as never)))
  for (let i = 0; i < 50 && !streamSignal; i++) await new Promise((r) => setTimeout(r, 20))
  c.destroy()
  for (let i = 0; i < 50 && !streamSignal?.aborted; i++) await new Promise((r) => setTimeout(r, 20))
  assert.equal(streamSignal?.aborted, true, 'the answer stream was cancelled when the app left')
})

test('notes lists only the asked spaces, personal only when asked', async () => {
  const { db, server, call } = await setup()
  insertExtraction(db, 'w', 'Zentro launch is on Friday.', note)
  insertExtraction(db, 'p', 'Hills trip in May.', { ...note, context: 'personal', summary: 'Hills trip' })
  const work = (await call({ id: 'n', type: 'notes' })).at(-1).notes as { summary: string }[]
  assert.deepEqual(work.map((n) => n.summary), ['Zentro launch is on Friday.'])
  const all = (await call({ id: 'm', type: 'notes', contexts: ['company', 'personal'] })).at(-1).notes as unknown[]
  assert.equal(all.length, 2)
  await server.close()
})

test('to-dos are listed and their status can be changed, but only to a known status', async () => {
  const { db, server, call } = await setup()
  insertExtraction(db, 'w', 'Ravi sends the deck.', { ...note, action_items: [{ text: 'Send the deck', owner: 'Ravi' }] })
  const todos = (await call({ id: 't', type: 'todos' })).at(-1).todos as { id: number; status: string }[]
  assert.equal(todos[0].status, 'open')
  assert.equal((await call({ id: 'u', type: 'todo', todoId: todos[0].id, status: 'done' })).at(-1).type, 'result')
  assert.equal(((await call({ id: 'v', type: 'todos' })).at(-1).todos as { status: string }[])[0].status, 'done')
  assert.equal((await call({ id: 'x', type: 'todo', todoId: todos[0].id, status: 'deleted' })).at(-1).code, 'bad_request')
  await server.close()
})

test('importing a file answers at once, saves its chunks in the background, reports progress, and skips repeats', async () => {
  const { db, server, call } = await setup()
  const text = '# Atlas\n\nAsha leads Atlas.\n\n# Orbit\n\nRavi owns Orbit.'
  const r = (await call({ id: 'i', type: 'importText', name: 'team.md', text })).at(-1)
  assert.equal(r.chunks, 2)
  for (let i = 0; i < 50; i++) {
    const s = (await call({ id: 's', type: 'status' })).at(-1)
    if (!s.importing) break
    await new Promise((res) => setTimeout(res, 20))
  }
  assert.equal((db.prepare("SELECT count(*) AS n FROM segments WHERE clip LIKE 'import:team.md#%'").get() as { n: number }).n, 2)
  const again = (await call({ id: 'j', type: 'importText', name: 'team.md', text })).at(-1)
  assert.equal(again.chunks, 0, 'already imported')
  await server.close()
})

test('several files sent at once are queued and all imported, one after another', async () => {
  const { db, server, call } = await setup([], {}, 30) // a slow model, so the first file is still importing
  const a = (await call({ id: 'a', type: 'importText', name: 'chatgpt.md', text: '# Atlas\n\nAsha leads Atlas.\n\n# Hills\n\nTrip planned.' })).at(-1)
  const b = (await call({ id: 'b', type: 'importText', name: 'claude.md', text: '# Orbit\n\nRavi owns Orbit.' })).at(-1)
  assert.equal(a.type, 'result'); assert.equal(b.type, 'result', 'the second file waits its turn instead of being refused')
  for (let i = 0; i < 100; i++) {
    const s = (await call({ id: 's', type: 'status' })).at(-1)
    if (!s.importing) break
    await new Promise((res) => setTimeout(res, 20))
  }
  assert.equal((db.prepare("SELECT count(*) AS n FROM segments WHERE clip LIKE 'import:claude.md%'").get() as { n: number }).n, 1)
  await server.close()
})

test('a huge import is refused before any model call', async () => {
  const calls: string[] = []
  const { server, call } = await setup(calls)
  const text = Array.from({ length: 300 }, (_, i) => `# Part ${i}\n\n${'Atlas notes. '.repeat(150)}`).join('\n\n')
  const r = (await call({ id: 'big', type: 'importText', name: 'huge.md', text })).at(-1)
  assert.equal(r.code, 'too_large')
  assert.equal(calls.length, 0)
  await server.close()
})

test('a write action asks the app first; a no means nothing is sent, and the steps show in the trace', async (t) => {
  const sent: string[] = []
  const sse = (events: object[]) => new Response(events.map((e) => `data: ${JSON.stringify(e)}\n\n`).join(''), { status: 200 })
  const fetch = (async (url: string, init: RequestInit = {}) => {
    const u = String(url)
    if (u.startsWith('https://api.typesafe.ai')) return new Response(JSON.stringify({ answers: { tier: { type: 'choice', choice: 'balanced', confidence: 0.9 } } }), { status: 200 })
    if (u.startsWith('https://connect.composio.dev')) {
      const msg = JSON.parse(String(init.body))
      if (msg.method === 'tools/call') sent.push(`execute ${msg.params.name}`)
      if (!msg.id) return new Response('', { status: 202 })
      const result = msg.method === 'tools/list' ? { tools: [{ name: 'COMPOSIO_MULTI_EXECUTE_TOOL', inputSchema: { type: 'object' } }] } : msg.method === 'tools/call' ? { content: [{ type: 'text', text: 'done' }] } : {}
      return new Response(JSON.stringify({ jsonrpc: '2.0', id: msg.id, result }), { status: 200, headers: { 'content-type': 'application/json' } })
    }
    const body = init.body ? JSON.parse(String(init.body)) : {}
    if (!body.stream) return new Response(JSON.stringify({ content: [{ type: 'text', text: '{}' }] }), { status: 200 })
    const last = body.messages.at(-1)
    if (Array.isArray(last.content) && last.content.some((b: { type: string; tool_use_id?: string }) => b.type === 'tool_result' && !String(b.tool_use_id).startsWith('ctx_'))) {
      sent.push(`result: ${last.content.find((b: { tool_use_id?: string }) => !String(b.tool_use_id).startsWith('ctx_')).content}`)
      return sse([{ type: 'content_block_start', index: 0, content_block: { type: 'text', text: '' } }, { type: 'content_block_delta', index: 0, delta: { type: 'text_delta', text: 'Okay, I did not send it.' } }, { type: 'message_delta', delta: { stop_reason: 'end_turn' } }])
    }
    return sse([{ type: 'content_block_start', index: 0, content_block: { type: 'tool_use', id: 'tu1', name: 'COMPOSIO_MULTI_EXECUTE_TOOL', input: {} } },
      { type: 'content_block_delta', index: 0, delta: { type: 'input_json_delta', partial_json: '{"tools":[{"tool_slug":"GMAIL_SEND_EMAIL","arguments":{"to":"asha@example.com"}}]}' } },
      { type: 'content_block_stop', index: 0 }, { type: 'message_delta', delta: { stop_reason: 'tool_use' } }])
  }) as unknown as typeof fetch
  const dir = mkdtempSync(join(tmpdir(), 'pika-'))
  const socketPath = join(dir, 's.sock')
  const server = await startServer({ socketPath, db: openDb(':memory:'), ledgerPath: join(dir, 'l.jsonl'), deps: { fetch, anthropicKey: 'ak', typesafeKey: 'tk', composioKey: 'ck' } })
  t.after(() => server.close())
  const answer = (approvalId: string, ok: boolean) => new Promise<void>((resolve) => {
    const c = net.createConnection(socketPath, () => c.write(encode({ id: 'ap', type: 'approve', approvalId, ok } as never)))
    c.on('data', () => { c.end(); resolve() })
  })
  const events: any[] = await new Promise((resolve) => {
    const got: any[] = []
    let buf = ''
    const c = net.createConnection(socketPath, () => c.write(encode({ id: 'a', type: 'ask', question: 'Email Asha that Atlas is late' } as never)))
    c.setEncoding('utf8')
    c.on('data', (d: string) => {
      buf += d
      const lines = buf.split('\n'); buf = lines.pop() ?? ''
      for (const l of lines.filter(Boolean)) {
        const m = JSON.parse(l); got.push(m)
        if (m.type === 'approval') void answer(m.approvalId, false)
        if (m.type === 'result' || m.type === 'error') { c.end(); resolve(got) }
      }
    })
  })
  const approval = events.find((e) => e.type === 'approval')
  assert.match(approval.action, /GMAIL_SEND_EMAIL/)
  assert.ok(!sent.some((s) => s.startsWith('execute')), 'nothing was executed')
  assert.ok(sent.some((s) => /declined/.test(s)), 'the model was told the user said no')
  assert.ok(events.some((e) => e.type === 'trace' && e.stage === 'tool' && e.name === 'COMPOSIO_MULTI_EXECUTE_TOOL'))
  assert.equal(events.at(-1).answer, 'Okay, I did not send it.')
})

test('an MCP server added from Settings keeps its secret out of the config, works at once, and can be removed', async (t) => {
  const dir = mkdtempSync(join(tmpdir(), 'pika-'))
  const socketPath = join(dir, 's.sock')
  const secrets = new Map<string, string>()
  const saved: object[][] = []
  const fetch = (async (url: string, init: RequestInit = {}) => {
    if (String(url).startsWith('https://locked.example')) return new Response('{}', { status: 401, headers: { 'www-authenticate': 'Bearer resource_metadata="https://locked.example/.well-known/oauth-protected-resource"' } })
    if (String(url).startsWith('https://mcp.example')) {
      const msg = JSON.parse(String(init.body))
      if (!msg.id) return new Response('', { status: 202 })
      const result = msg.method === 'tools/list' ? { tools: [{ name: 'list_tickets' }, { name: 'create_ticket' }] } : {}
      return new Response(JSON.stringify({ jsonrpc: '2.0', id: msg.id, result }), { status: 200 })
    }
    return new Response('{}', { status: 200 })
  }) as unknown as typeof fetch
  const server = await startServer({ socketPath, db: openDb(':memory:'), ledgerPath: join(dir, 'l.jsonl'), deps: { fetch, anthropicKey: 'ak', typesafeKey: 'tk',
    secrets: { set: (k, v) => { secrets.set(k, v) }, remove: (k) => { secrets.delete(k) } }, saveMcp: (list) => { saved.push(list) } } })
  t.after(() => server.close())
  const call = (req: object): Promise<any> => new Promise((resolve) => {
    let buf = ''
    const c = net.createConnection(socketPath, () => c.write(encode(req as never)))
    c.on('data', (d) => { buf += d; if (buf.includes('\n')) { c.end(); resolve(JSON.parse(buf.split('\n')[0])) } })
  })
  assert.equal((await call({ id: 'a', type: 'addMcp', name: 'tickets', url: 'http://mcp.example', headerName: 'Authorization', headerValue: 'Bearer s3cret' })).code, 'bad_request', 'https only')
  assert.equal((await call({ id: 'b', type: 'addMcp', name: 'tickets', url: 'https://mcp.example/mcp', headerName: 'Authorization', headerValue: 'Bearer s3cret' })).type, 'result')
  assert.equal(secrets.get('mcp:tickets'), 'Bearer s3cret')
  assert.ok(!JSON.stringify(saved.at(-1)).includes('s3cret'), 'the secret is not in the saved config')
  assert.deepEqual((await call({ id: 'c', type: 'connectors' })).servers, [{ name: 'tickets', tools: 2, url: 'https://mcp.example/mcp', needsSignIn: false }])
  await call({ id: 'g', type: 'addMcp', name: 'locked', url: 'https://locked.example/mcp' })
  const locked = (await call({ id: 'h', type: 'connectors' })).servers.find((x: { name: string }) => x.name === 'locked')
  assert.equal(locked.needsSignIn, true, 'a server that answers 401 shows a sign-in button')
  await call({ id: 'i', type: 'removeMcp', name: 'locked' })
  await call({ id: 'd', type: 'removeMcp', name: 'tickets' })
  assert.deepEqual((await call({ id: 'e', type: 'connectors' })).servers, [])
  assert.equal(secrets.has('mcp:tickets'), false)
})

test('a handover: the app sees Jarvis ask for help, the user types and continues, and Jarvis carries on', async (t) => {
  const typed: string[] = []
  const sse = (events: object[]) => new Response(events.map((e) => `data: ${JSON.stringify(e)}\n\n`).join(''), { status: 200 })
  const fetch = (async (url: string, init: RequestInit = {}) => {
    if (String(url).startsWith('https://api.typesafe.ai')) return new Response(JSON.stringify({ answers: { tier: { type: 'choice', choice: 'balanced', confidence: 0.9 } } }))
    const body = init.body ? JSON.parse(String(init.body)) : {}
    if (!body.stream) return new Response(JSON.stringify({ content: [{ type: 'text', text: '{}' }] }))
    const last = body.messages.at(-1)
    if (Array.isArray(last.content) && last.content.some((b: { type: string; tool_use_id?: string }) => b.type === 'tool_result' && !String(b.tool_use_id).startsWith('ctx_')))
      return sse([{ type: 'content_block_start', index: 0, content_block: { type: 'text', text: '' } }, { type: 'content_block_delta', index: 0, delta: { type: 'text_delta', text: `Thanks. ${last.content.find((b: { tool_use_id?: string }) => !String(b.tool_use_id).startsWith('ctx_')).content}` } }, { type: 'message_delta', delta: { stop_reason: 'end_turn' } }])
    return sse([{ type: 'content_block_start', index: 0, content_block: { type: 'tool_use', id: 't1', name: 'browser_ask_user', input: {} } },
      { type: 'content_block_delta', index: 0, delta: { type: 'input_json_delta', partial_json: '{"reason":"Please log in to Linear"}' } }, { type: 'content_block_stop', index: 0 }, { type: 'message_delta', delta: { stop_reason: 'tool_use' } }])
  }) as unknown as typeof fetch
  const view = { url: 'https://linear.app/login', title: 'Log in', text: '' }
  const browser = { open: async () => view, read: async () => view, click: async () => view, type: async () => view, screenshot: async () => Buffer.from('jpg'),
    check: async (l: string) => ({ name: l, sendsForm: false }), checkField: async () => ({ secret: false }),
    userClick: async () => {}, userType: async (x: string) => { typed.push(x) }, userKey: async () => {}, userScroll: async () => {} }
  const dir = mkdtempSync(join(tmpdir(), 'pika-'))
  const socketPath = join(dir, 's.sock')
  const server = await startServer({ socketPath, db: openDb(':memory:'), ledgerPath: join(dir, 'l.jsonl'), deps: { fetch, anthropicKey: 'ak', typesafeKey: 'tk', browser } })
  t.after(() => server.close())
  const once = (req: object): Promise<any> => new Promise((resolve) => {
    let buf = ''
    const c = net.createConnection(socketPath, () => c.write(encode(req as never)))
    c.on('data', (d) => { buf += d; if (buf.includes('\n')) { c.end(); resolve(JSON.parse(buf.split('\n')[0])) } })
  })
  assert.equal((await once({ id: 'x', type: 'browserInput', input: { kind: 'type', text: 'early' } })).type, 'error', 'no input while nobody asked')
  const states: string[] = []
  const watcher = net.createConnection(socketPath, () => watcher.write(encode({ id: 'w', type: 'watchBrowser' } as never)))
  watcher.setEncoding('utf8')
  let wbuf = ''
  let handled = false
  watcher.on('data', (d: string) => {
    wbuf += d; const lines = wbuf.split('\n'); wbuf = lines.pop() ?? ''
    for (const l of lines.filter(Boolean)) {
      const m = JSON.parse(l); states.push(m.state)
      if (m.state === 'needsUser' && m.reason === 'Please log in to Linear' && !handled) void (async () => {
        handled = true // frames repeat the state; act once
        await once({ id: 'i', type: 'browserInput', input: { kind: 'type', text: 'me@example.com' } })
        await once({ id: 'r', type: 'browserResume', note: 'logged in' })
      })()
    }
  })
  t.after(() => watcher.destroy())
  const answer = await new Promise<any>((resolve) => {
    let buf = ''
    const c = net.createConnection(socketPath, () => c.write(encode({ id: 'a', type: 'ask', question: 'Check my Linear issues' } as never)))
    c.setEncoding('utf8')
    c.on('data', (d: string) => { buf += d; for (const l of buf.split('\n').filter(Boolean)) { try { const m = JSON.parse(l); if (m.type === 'result') { c.end(); resolve(m) } } catch {} } })
  })
  assert.deepEqual(typed, ['me@example.com'])
  assert.match(answer.answer, /logged in/)
  assert.ok(states.includes('needsUser') && states.at(-1) === 'idle', 'back to idle when the answer ends')
})

test('if the app leaves mid-handover, the handover ends instead of waiting for nobody', async (t) => {
  const sse = (events: object[]) => new Response(events.map((e) => `data: ${JSON.stringify(e)}\n\n`).join(''), { status: 200 })
  const fetch = (async (url: string, init: RequestInit = {}) => {
    if (String(url).startsWith('https://api.typesafe.ai')) return new Response(JSON.stringify({ answers: { tier: { type: 'choice', choice: 'balanced', confidence: 0.9 } } }))
    if (init.signal?.aborted) throw new DOMException('aborted', 'AbortError') // like the real API, a cancelled request does not answer
    const body = init.body ? JSON.parse(String(init.body)) : {}
    if (!body.stream) return new Response(JSON.stringify({ content: [{ type: 'text', text: '{}' }] }))
    return sse([{ type: 'content_block_start', index: 0, content_block: { type: 'tool_use', id: 't1', name: 'browser_ask_user', input: {} } },
      { type: 'content_block_delta', index: 0, delta: { type: 'input_json_delta', partial_json: '{"reason":"log in"}' } }, { type: 'content_block_stop', index: 0 }, { type: 'message_delta', delta: { stop_reason: 'tool_use' } }])
  }) as unknown as typeof fetch
  const view = { url: 'https://x.example/', title: '', text: '' }
  const browser = { open: async () => view, read: async () => view, click: async () => view, type: async () => view, screenshot: async () => Buffer.from('j'),
    check: async (l: string) => ({ name: l, sendsForm: false }), checkField: async () => ({ secret: false }), userClick: async () => {}, userType: async () => {}, userKey: async () => {}, userScroll: async () => {} }
  const dir = mkdtempSync(join(tmpdir(), 'pika-'))
  const socketPath = join(dir, 's.sock')
  const server = await startServer({ socketPath, db: openDb(':memory:'), ledgerPath: join(dir, 'l.jsonl'), deps: { fetch, anthropicKey: 'ak', typesafeKey: 'tk', browser } })
  t.after(() => server.close())
  const states: string[] = []
  const watcher = net.createConnection(socketPath, () => watcher.write(encode({ id: 'w', type: 'watchBrowser' } as never)))
  watcher.setEncoding('utf8')
  let wb = ''
  watcher.on('data', (d: string) => { wb += d; const ls = wb.split('\n'); wb = ls.pop() ?? ''; for (const l of ls.filter(Boolean)) states.push(JSON.parse(l).state) })
  const asker = net.createConnection(socketPath, () => asker.write(encode({ id: 'a', type: 'ask', question: 'log me in' } as never)))
  for (let i = 0; i < 100 && !states.includes('needsUser'); i++) await new Promise((r) => setTimeout(r, 20))
  assert.ok(states.includes('needsUser'))
  asker.destroy() // the app went away (interrupted or quit)
  for (let i = 0; i < 100 && states.at(-1) !== 'idle'; i++) await new Promise((r) => setTimeout(r, 20))
  assert.equal(states.at(-1), 'idle')
  watcher.destroy()
})

test('the app can ask for an image: unknown links wait for a click', async () => {
  const { server, call } = await setup()
  const r = (await call({ id: 'im', type: 'image', url: 'https://elsewhere.example/x.png' })).at(-1)
  assert.equal(r.status, 'ask')
  assert.equal((await call({ id: 'im2', type: 'image', url: 'http://elsewhere.example/x.png', clicked: true })).at(-1).status, 'blocked')
  await server.close()
})

test('forget removes the segment and its entities', async () => {
  const { db, server, call } = await setup()
  const id = insertExtraction(db, 'clip-1', 'Zentro launch is on Friday.', note) as number
  const r = await call({ id: 'f', type: 'forget', segmentId: id })
  assert.equal(r.at(-1).type, 'result')
  assert.equal((db.prepare('SELECT count(*) AS n FROM entities').get() as { n: number }).n, 0)
  await server.close()
})

test('paused cloud refuses ask and ingest and sends nothing', async () => {
  const calls: string[] = []
  const { db, server, call } = await setup(calls)
  insertExtraction(db, 'clip-1', 'Zentro launch is on Friday.', note)
  await call({ id: 's', type: 'settings', pauseCloud: true })
  for (const req of [{ id: 'a', type: 'ask', question: 'Zentro launch' }, { id: 'i', type: 'ingest', text: 'hello', clipId: 'c' }]) {
    const r = await call(req)
    assert.equal(r.at(-1).code, 'paused')
  }
  assert.equal(calls.length, 0)
  await server.close()
})

test('ledger lists outbound calls and never a key', async () => {
  const { db, server, call, ledgerPath } = await setup()
  insertExtraction(db, 'clip-1', 'Zentro launch is on Friday.', note)
  await call({ id: 'a', type: 'ask', question: 'Zentro launch Friday' })
  const r = await call({ id: 'l', type: 'ledger', limit: 10 })
  const rows = r.at(-1).rows as { host: string }[]
  assert.ok(rows.some((x) => x.host === 'api.anthropic.com'))
  assert.ok(rows.some((x) => x.host === 'api.typesafe.ai'))
  assert.ok(!JSON.stringify(rows).includes('"tk"') && !JSON.stringify(rows).includes('"ak"'))
  await server.close()
})

test('graph honours spaces and status reports pause state', async () => {
  const { db, server, call } = await setup()
  insertExtraction(db, 'c1', 'x', note)
  insertExtraction(db, 'c2', 'y', { ...note, context: 'personal', entities: [{ name: 'Home', type: 'topic' }] })
  const g = (await call({ id: 'g', type: 'graph', contexts: ['company'] })).at(-1)
  assert.deepEqual(g.nodes.map((n: any) => n.name), ['Zentro'])
  const all = (await call({ id: 'g2', type: 'graph' })).at(-1)
  assert.deepEqual(all.nodes.map((n: any) => n.name).sort(), ['Home', 'Zentro'])
  assert.equal(all.details[String(all.nodes[0].id)].segments.length, 1)
  const s = (await call({ id: 's', type: 'status' })).at(-1)
  assert.equal(s.pauseCloud, false)
  await server.close()
})

test('a reminder that came due while the app was away arrives when it connects, once, and can be snoozed', async () => {
  const { db, server, call, socketPath } = await setup()
  // Set a minute ago (as if the app had been closed since), straight into the table the server reads.
  const past = new Reminders(db, () => new Date(Date.now() - 120_000))
  const d = new Date(Date.now() - 60_000)
  const local = `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}-${String(d.getDate()).padStart(2, '0')}T${String(d.getHours()).padStart(2, '0')}:${String(d.getMinutes()).padStart(2, '0')}`
  const r = past.add({ text: 'Call the bank', at: local })
  const watch = (): Promise<any> => new Promise((resolve, reject) => {
    let buf = ''
    const c = net.createConnection(socketPath, () => c.write(encode({ id: 'w', type: 'watchTasks' } as never)))
    const timer = setTimeout(() => { c.end(); resolve(undefined) }, 300)
    c.on('data', (d) => {
      const out = decodeLines(buf + d.toString('utf8')); buf = out.rest
      const hit = (out.messages as any[]).find((m) => m.type === 'reminder')
      if (hit) { clearTimeout(timer); c.end(); resolve(hit) }
    })
    c.on('error', reject)
  })
  const got = await watch()
  assert.equal(got?.text, 'Call the bank')
  assert.equal(got?.reminderId, r.id)
  assert.equal(await watch(), undefined, 'delivered once')
  assert.equal((await call({ id: 's', type: 'reminder', reminderId: r.id, action: 'snooze', minutes: 10 })).at(-1).ok, true)
  assert.equal(new Reminders(db).list().length, 1, 'snoozed: waiting again')
  await server.close()
})

test('background tasks: cancelling one that does not exist says so', async () => {
  const { server, call } = await setup()
  assert.equal((await call({ id: 'c', type: 'cancelTask', taskId: 'nope' })).at(-1).ok, false)
  await server.close()
})

test('queued imports stop when cloud processing is paused, and the same file sent twice is imported once', async () => {
  const calls: string[] = []
  const { db, server, call } = await setup(calls, {}, 20)
  const text = '# A\n\nAsha leads Atlas.\n\n# B\n\nRavi owns Orbit.'
  await call({ id: 'a', type: 'importText', name: 'x.md', text })
  await call({ id: 'b', type: 'importText', name: 'x.md', text })
  for (let i = 0; i < 100; i++) { if (!(await call({ id: 's', type: 'status' })).at(-1).importing) break; await new Promise((r) => setTimeout(r, 20)) }
  assert.equal((db.prepare("SELECT count(*) AS n FROM segments WHERE clip LIKE 'import:x.md%'").get() as { n: number }).n, 2, 'each part once')
  await call({ id: 'c', type: 'importText', name: 'y.md', text: '# C\n\nOne.\n\n# D\n\nTwo.\n\n# E\n\nThree.' })
  await call({ id: 'p', type: 'settings', pauseCloud: true })
  const before = calls.length
  await new Promise((r) => setTimeout(r, 200))
  assert.ok(calls.length - before <= 2, 'at most the part already in flight goes out after the pause')
  await server.close()
})

test('a request too large to accept gets an error reply, not a dropped connection', async () => {
  const { server, call } = await setup()
  const r = await call({ id: 'big', type: 'importText', name: 'x.md', text: 'x'.repeat(46_000_000) })
  assert.equal(r.at(-1).type, 'error')
  assert.equal(r.at(-1).code, 'too_large')
  await server.close()
})

test('meeting notes: an empty meeting is an error, and nothing is written while online services are paused', async () => {
  const { server, call } = await setup()
  const empty = (await call({ id: 'm', type: 'meetingNote', meetingId: 'x', lines: [], started: '2026-10-23T10:00:00Z' })).at(-1)
  assert.equal(empty.type, 'error')
  assert.match(empty.message, /nothing was said/)
  await call({ id: 'p', type: 'settings', pauseCloud: true })
  const paused = (await call({ id: 'm2', type: 'meetingNote', meetingId: 'x', lines: [{ at: '', speaker: 'Me', text: 'hi' }], started: '' })).at(-1)
  assert.equal(paused.code, 'paused')
  await server.close()
})

test('setup: a fresh install with no keys still answers the app, shows what is missing, and saves a working key', async () => {
  const dir = mkdtempSync(join(tmpdir(), 'pika-'))
  const socketPath = join(dir, 's.sock')
  const saved: Record<string, string> = {}
  let restarts = 0
  const fetch = (async (url: string, init: RequestInit = {}) => {
    const key = (init.headers as Record<string, string>)['x-api-key']
    if (String(url).endsWith('/v1/models')) return new Response('{}', { status: key === 'sk-good' ? 200 : 401 })
    return new Response('{}', { status: 500 })
  }) as unknown as typeof globalThis.fetch
  const server = await startServer({ socketPath, db: openDb(':memory:'), ledgerPath: join(dir, 'l.jsonl'), deps: {
    fetch, anthropicKey: '', typesafeKey: '', secrets: { set: (k, v) => { saved[k] = v }, remove: () => {} }, restart: () => { restarts++ } } })
  const call = (req: object): Promise<any> => new Promise((resolve, reject) => {
    let buf = ''
    const c = net.createConnection(socketPath, () => c.write(encode(req as never)))
    c.on('data', (d) => { const r = decodeLines(buf + d.toString('utf8')); buf = r.rest; for (const m of r.messages as any[]) if (m.type === 'result' || m.type === 'error') { c.end(); resolve(m) } })
    c.on('error', reject)
  })
  const ask = await call({ id: 'a', type: 'ask', question: 'hi' })
  assert.equal(ask.code, 'setup')
  const status = await call({ id: 's', type: 'setup' })
  const anthropic = status.keys.find((k: any) => k.name === 'ANTHROPIC_API_KEY')
  assert.deepEqual([anthropic.set, anthropic.required], [false, true])
  assert.ok(status.keys.every((k: any) => typeof k.purpose === 'string' && !('value' in k)))
  assert.equal((await call({ id: 'x', type: 'setKey', name: 'PATH', value: 'x' })).code, 'bad_request')
  assert.match((await call({ id: 'b', type: 'setKey', name: 'ANTHROPIC_API_KEY', value: 'sk-bad' })).message, /rejected/)
  assert.deepEqual(saved, {})
  assert.equal((await call({ id: 'g', type: 'setKey', name: 'ANTHROPIC_API_KEY', value: ' sk-good\n' })).ok, true)
  assert.deepEqual(saved, { ANTHROPIC_API_KEY: 'sk-good' })
  await new Promise((r) => setTimeout(r, 50))
  assert.equal(restarts, 1, 'the companion restarts to use the new key')
  await server.close()
})
