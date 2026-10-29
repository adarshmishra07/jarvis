import { speedParams, type LlmDeps } from './llm.ts'

// A streaming answer that can use tools: the model asks, the companion runs the tool, the result goes back, and the
// model carries on, until it answers or the step limit is reached. All text is streamed as it arrives.

const API_URL = 'https://api.anthropic.com/v1/messages'
const STREAM_TIMEOUT_MS = 90_000
const DEFAULT_MAX_STEPS = 8
const REPEAT_LIMIT = 3
const REPEATED = 'You have run the same action with the same input three times. Stop repeating it: try a different approach, hand the browser to the user if a page needs them, or tell the user what is blocking you.'
const WRAP_UP = 'Step limit reached. In plain words, tell the user what you did, what is left, and what they or you should do next. Do not use tools.'

export interface ToolKit {
  definitions: object[]
  /** Runs one tool call and returns what the model should see. Throwing tells the model it failed. */
  run: (name: string, input: unknown) => Promise<string>
  /** Extra request fields (for example remote MCP servers) and the beta header they need. */
  extra?: Record<string, unknown>
  beta?: string
  /** Hides values that must never be saved (what the user sent for a login). */
  redact?: (text: string) => string
}

type Block = Record<string, unknown> & { type: string }
interface Message { role: 'user' | 'assistant'; content: unknown }

export interface AgentRequest {
  model: string
  system: string
  messages: Message[]
  maxTokens: number
  deps: LlmDeps
  onText: (text: string) => void
  tools: ToolKit
  maxSteps?: number
  signal?: AbortSignal
  /** Each tool call with what came back, so later turns can still see it. */
  onStep?: (name: string, input: unknown, result: string, error: boolean) => void
}

/** One streamed model turn: its content blocks (rebuilt from the stream) and why it stopped. */
async function turn(req: AgentRequest, messages: Message[], noTools = false): Promise<{ blocks: Block[]; stop: string }> {
  const stop = req.signal ? AbortSignal.any([req.signal, AbortSignal.timeout(STREAM_TIMEOUT_MS)]) : AbortSignal.timeout(STREAM_TIMEOUT_MS)
  const headers: Record<string, string> = { 'x-api-key': req.deps.apiKey, 'anthropic-version': '2023-06-01', 'content-type': 'application/json' }
  if (req.tools.beta) headers['anthropic-beta'] = req.tools.beta
  const response = await req.deps.fetch(API_URL, {
    signal: stop, method: 'POST', headers,
    body: JSON.stringify({ model: req.model, max_tokens: req.maxTokens, stream: true, ...speedParams(req.model), system: req.system, messages,
      ...(req.tools.definitions.length ? { tools: req.tools.definitions } : {}), ...req.tools.extra, ...(noTools ? { tool_choice: { type: 'none' } } : {}) }),
  })
  if (!response.ok || !response.body) {
    // The API's own explanation describes the request's shape (never the user's text), so it is safe to pass on.
    const reason = await response.json().then((j: { error?: { message?: string } }) => j.error?.message ?? '', () => '')
    throw new Error(`anthropic request failed: ${response.status}${reason ? ` (${reason.slice(0, 300)})` : ''}`)
  }

  const blocks: Block[] = []
  const partial: string[] = []
  let stopReason = 'end_turn'
  const handle = (line: string): void => {
    if (!line.startsWith('data:')) return
    const e = JSON.parse(line.slice(5).trim()) as { type: string; index?: number; content_block?: Block; delta?: Record<string, string> }
    if (e.type === 'error') throw new Error('anthropic stream error')
    const i = e.index ?? 0
    if (e.type === 'content_block_start' && e.content_block) { blocks[i] = { ...e.content_block }; partial[i] = '' }
    if (e.type === 'content_block_delta' && e.delta && !blocks[i] && e.delta.type === 'text_delta') { blocks[i] = { type: 'text', text: '' }; partial[i] = '' } // text with no start event
    if (e.type === 'content_block_delta' && e.delta && blocks[i]) {
      const d = e.delta
      if (d.type === 'text_delta') { blocks[i].text = String(blocks[i].text ?? '') + d.text; req.onText(d.text) }
      if (d.type === 'input_json_delta') partial[i] += d.partial_json
      if (d.type === 'thinking_delta') blocks[i].thinking = String(blocks[i].thinking ?? '') + d.thinking
      if (d.type === 'signature_delta') blocks[i].signature = d.signature
    }
    if (e.type === 'content_block_stop' && blocks[i] && partial[i]) blocks[i].input = JSON.parse(partial[i])
    if (e.type === 'message_delta' && e.delta?.stop_reason) stopReason = e.delta.stop_reason
  }
  const decoder = new TextDecoder()
  const reader = response.body.getReader()
  let pending = ''
  for (;;) {
    const { done, value } = await reader.read()
    if (done) break
    pending += decoder.decode(value, { stream: true })
    const lines = pending.split('\n')
    pending = lines.pop() ?? ''
    for (const l of lines) handle(l.trimEnd())
  }
  if (pending.trim()) handle(pending.trim())
  return { blocks: blocks.filter(Boolean), stop: stopReason }
}

export async function streamAgent(req: AgentRequest): Promise<string> {
  const messages = [...req.messages]
  let text = ''
  // Text from the next step starts with a space when the previous step's text did not end with one.
  let pendingSpace = false
  const onText = (t: string): void => {
    if (pendingSpace && t && !/^\s/.test(t)) { text += ' '; req.onText(' ') }
    pendingSpace = false
    text += t
    req.onText(t)
  }
  let lastCall = ''
  let repeats = 0
  for (let step = 0; step < (req.maxSteps ?? DEFAULT_MAX_STEPS); step++) {
    const { blocks, stop } = await turn({ ...req, onText }, messages)
    pendingSpace = text.length > 0 && !/\s$/.test(text)
    messages.push({ role: 'assistant', content: blocks })
    if (stop === 'pause_turn') continue // a server-side tool is still working: let it carry on
    const calls = blocks.filter((b) => b.type === 'tool_use')
    if (stop !== 'tool_use' || !calls.length) return text
    const results = []
    for (const c of calls) {
      const key = `${String(c.name)} ${JSON.stringify(c.input ?? {})}`
      repeats = key === lastCall ? repeats + 1 : 1
      lastCall = key
      req.signal?.throwIfAborted() // cancelled: nothing more runs, not even the rest of this turn's calls
      let result: { type: string; tool_use_id: unknown; content: string; is_error?: boolean }
      if (repeats >= REPEAT_LIMIT) result = { type: 'tool_result', tool_use_id: c.id, is_error: true, content: REPEATED }
      else try {
        result = { type: 'tool_result', tool_use_id: c.id, content: await req.tools.run(String(c.name), c.input ?? {}) }
      } catch (e) {
        // Marked as an error, with what went wrong, so the model changes course instead of trusting a failed step.
        result = { type: 'tool_result', tool_use_id: c.id, is_error: true, content: `That did not work: ${e instanceof Error ? e.message : 'unknown error'}. Try another way, or tell the user what is blocking you.` }
      }
      results.push(result)
      req.onStep?.(String(c.name), c.input ?? {}, result.content, result.is_error === true)
    }
    messages.push({ role: 'user', content: results })
  }
  // Out of steps: one last turn without tool use, so the answer says where things stand instead of stopping mid-task.
  const last = messages.at(-1)!
  last.content = [...(last.content as object[]), { type: 'text', text: WRAP_UP }]
  const { blocks } = await turn({ ...req, onText }, messages, true)
  return text + blocks.filter((b) => b.type === 'text').map((b) => String(b.text ?? '')).join('')
}

/** Several toolkits as one: definitions together, each call routed to the kit that defines it. */
export function combineTools(kits: ToolKit[]): ToolKit {
  const owner = new Map<string, ToolKit>()
  for (const k of kits) for (const d of k.definitions as { name: string }[]) owner.set(d.name, k)
  return {
    definitions: kits.flatMap((k) => k.definitions),
    run: async (name, input) => { const k = owner.get(name); if (!k) throw new Error(`unknown tool ${name}`); return k.run(name, input) },
    redact: (text) => kits.reduce((t, k) => (k.redact ? k.redact(t) : t), text),
    extra: Object.assign({}, ...kits.map((k) => k.extra ?? {})),
    beta: kits.map((k) => k.beta).filter(Boolean).join(',') || undefined,
  }
}
