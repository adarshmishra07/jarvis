// Newline-delimited JSON between the app and the companion. One message per line.
/** Questions can carry attached files (up to about 30 MB, base64). */
export const MAX_LINE_BYTES = 45_000_000

export type Space = 'company' | 'professional' | 'personal'

export type Request =
  | { id: string; type: 'ask'; question: string; contexts?: Space[]; history?: { role: 'user' | 'assistant'; content: string; work?: string; id?: string }[]; summary?: string; voice?: boolean; files?: { name: string; data: string; transcript?: boolean }[] }
  | { id: string; type: 'research'; question: string }
  | { id: string; type: 'ingest'; text: string; clipId: string }
  | { id: string; type: 'graph'; contexts?: Space[] }
  | { id: string; type: 'forget'; segmentId: number }
  | { id: string; type: 'forgetMeeting'; meetingId: string }
  | { id: string; type: 'setup' }
  | { id: string; type: 'setKey'; name: string; value: string }
  | { id: string; type: 'restore'; segmentId: number }
  | { id: string; type: 'importText'; name: string; text: string }
  | { id: string; type: 'approve'; approvalId: string; ok: boolean }
  | { id: string; type: 'connectors' }
  | { id: string; type: 'apps' }
  | { id: string; type: 'connectApp'; toolkit: string; alias?: string }
  | { id: string; type: 'removeApp'; toolkit: string; accountId: string }
  | { id: string; type: 'renameApp'; toolkit: string; accountId: string; alias: string }
  | { id: string; type: 'addMcp'; name: string; url: string; headerName?: string; headerValue?: string }
  | { id: string; type: 'removeMcp'; name: string }
  | { id: string; type: 'skills' }
  | { id: string; type: 'installSkill'; source: string }
  | { id: string; type: 'setSkill'; name: string; enabled?: boolean; autoRun?: boolean }
  | { id: string; type: 'removeSkill'; name: string }
  | { id: string; type: 'mcpSignIn'; name: string }
  | { id: string; type: 'watchBrowser' }
  | { id: string; type: 'image'; url: string; clicked?: boolean }
  | { id: string; type: 'browserInput'; input: { kind: 'click'; x: number; y: number } | { kind: 'type'; text: string } | { kind: 'key'; key: string } | { kind: 'scroll'; dy: number } }
  | { id: string; type: 'browserResume'; note?: string }
  | { id: string; type: 'notes'; contexts?: Space[]; limit?: number }
  | { id: string; type: 'todos'; contexts?: Space[] }
  | { id: string; type: 'todo'; todoId: number; status: 'open' | 'done' | 'dropped' }
  | { id: string; type: 'ledger'; limit?: number }
  | { id: string; type: 'status' }
  | { id: string; type: 'update' }
  | { id: string; type: 'watchTasks' }
  | { id: string; type: 'cancelTask'; taskId: string }
  | { id: string; type: 'meetingNote'; meetingId: string; lines: { at: string; speaker: 'Me' | 'Them'; text: string }[]; started: string }
  | { id: string; type: 'reminder'; reminderId: number; action: 'snooze' | 'cancel'; minutes?: number }
  | { id: string; type: 'settings'; pauseCloud?: boolean; instructions?: string[] }
  | { id: string; type: 'feedback'; rating: 'up' | 'down'; question: string; answer: string; model?: string }

export type Event =
  | { id: string; type: 'sentence'; text: string }
  | { id: string; type: 'token'; text: string }
  | { id: string; type: 'trace'; stage: string; [key: string]: unknown }
  | { id: string; type: 'approval'; approvalId: string; action: string }
  | { id: string; type: 'screenshot'; jpeg: string }
  | { id: string; type: 'image'; mime: string; data: string }
  | { id: string; type: 'browser'; state: string; reason?: string; url?: string; frame?: string }
  | { id: string; type: 'reminder'; reminderId: number; text: string; run: boolean }
  | { id: string; type: 'control'; action: 'startNotes' | 'stopNotes' }
  | { id: string; type: 'result'; [key: string]: unknown }
  | { id: string; type: 'error'; code: string; message: string }

export function encode(message: Event | Request): string {
  return JSON.stringify(message) + '\n'
}

/** Splits a buffer into complete JSON lines; a partial last line is returned in `rest`. */
export function decodeLines(buffer: string): { messages: unknown[]; rest: string } {
  const parts = buffer.split('\n')
  const rest = parts.pop() ?? ''
  if (Buffer.byteLength(rest) > MAX_LINE_BYTES) throw new Error('line too long')
  const messages = parts.filter((l) => l.trim()).map((line) => {
    if (Buffer.byteLength(line) > MAX_LINE_BYTES) throw new Error('line too long')
    return JSON.parse(line) as unknown
  })
  return { messages, rest }
}
