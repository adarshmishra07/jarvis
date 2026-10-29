import { test } from 'node:test'
import assert from 'node:assert/strict'
import { SentenceSplitter, speakable } from './speech.ts'

test('emits complete sentences as text streams in, and the rest on flush', () => {
  const s = new SentenceSplitter()
  assert.deepEqual(s.push('Hello there. How are'), ['Hello there.'])
  assert.deepEqual(s.push(' you? Fi'), ['How are you?'])
  assert.deepEqual(s.push('ne'), [])
  assert.deepEqual(s.flush(), ['Fine'])
  assert.deepEqual(s.flush(), [])
})

test('does not split on decimals, version numbers or a trailing period with no space yet', () => {
  const s = new SentenceSplitter()
  assert.deepEqual(s.push('It costs 3.5 dollars on v2.1 today.'), [])
  assert.deepEqual(s.push(' Next one.'), ['It costs 3.5 dollars on v2.1 today.'])
  assert.deepEqual(s.flush(), ['Next one.'])
})

test('splits on the Hindi danda and on blank lines and list items', () => {
  const s = new SentenceSplitter()
  assert.deepEqual(s.push('कल लॉन्च है। सब तैयार है। '), ['कल लॉन्च है।', 'सब तैयार है।'])
  const t = new SentenceSplitter()
  assert.deepEqual(t.push('First point\n- second point\n\nThird'), ['First point', '- second point'])
  assert.deepEqual(t.flush(), ['Third'])
})

test('speakable removes citations, markdown marks and links so they are not read aloud', () => {
  assert.equal(speakable('Priya owns it [1][2].'), 'Priya owns it.')
  assert.equal(speakable('**Bold** and `code` and # heading'), 'Bold and code and heading')
  assert.equal(speakable('- item one'), 'item one')
  assert.equal(speakable('See [the docs](https://x.example/a) now'), 'See the docs now')
  assert.equal(speakable('[1]'), '')
})

test('table bars and list numbers are never read aloud', () => {
  assert.equal(speakable('| Atlas | Friday |'), 'Atlas Friday')
  assert.equal(speakable('2. Ship the deck.'), 'Ship the deck.')
})
