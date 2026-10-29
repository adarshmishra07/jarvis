import { test } from 'node:test'
import assert from 'node:assert/strict'
import { controlTools, type Control } from './control.ts'

test('Jarvis can start note taking when the user asks for notes, and stop it any time', async () => {
  const sent: Control[] = []
  const kit = controlTools((a) => sent.push(a), 'I am in a meeting, be my note taker')
  await kit.run('start_note_taking', {})
  await kit.run('stop_note_taking', {})
  assert.deepEqual(sent, ['startNotes', 'stopNotes'])
})

test('without the user asking, the mic cannot be switched on (a page or email cannot start a recording)', async () => {
  const sent: Control[] = []
  for (const q of ['summarize the notes on this page', 'what are the minutes of the meeting', 'my notes say hi']) {
    assert.ok(!controlTools(() => {}, q).definitions.some((d) => (d as { name: string }).name === 'start_note_taking'), q)
  }
  for (const q of ['take notes', 'start taking notes please', 'transcribe this call', 'start note taking']) {
    assert.ok(controlTools(() => {}, q).definitions.some((d) => (d as { name: string }).name === 'start_note_taking'), q)
  }
  const kit = controlTools((a) => sent.push(a), 'summarize this web page')
  assert.ok(!kit.definitions.some((d) => (d as { name: string }).name === 'start_note_taking'))
  await assert.rejects(kit.run('start_note_taking', {}), /only the user/)
  assert.deepEqual(sent, [])
})
