import { test } from 'node:test'
import assert from 'node:assert/strict'
import { encode, decodeLines, MAX_LINE_BYTES } from './protocol.ts'

test('splits complete lines and keeps a partial last line', () => {
  const r = decodeLines('{"a":1}\n{"b":2}\n{"c"')
  assert.deepEqual(r.messages, [{ a: 1 }, { b: 2 }])
  assert.equal(r.rest, '{"c"')
})

test('Hindi text and embedded newlines survive a round trip', () => {
  const text = 'नमस्ते\nline two'
  const line = encode({ id: '1', type: 'sentence', text })
  assert.equal(line.split('\n').length, 2) // the newline inside the text is escaped
  assert.deepEqual(decodeLines(line).messages, [{ id: '1', type: 'sentence', text }])
})

test('rejects a line over the size limit', () => {
  assert.throws(() => decodeLines('x'.repeat(MAX_LINE_BYTES + 1)), /too long/)
  assert.throws(() => decodeLines('x'.repeat(MAX_LINE_BYTES + 1) + '\n'), /too long/)
})
