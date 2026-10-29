import { test } from 'node:test'
import assert from 'node:assert/strict'
import { chunkMarkdown } from './chunk.ts'

test('splits on headings and records the heading path as the source', () => {
  const md = '# Work\nintro line\n## Launch\nPriya owns pricing.\n## Hiring\nTwo roles open.\n# Home\nBuy milk.'
  const chunks = chunkMarkdown(md, 'notes.md', 1000)
  assert.deepEqual(chunks.map((c) => c.source), ['notes.md#Work', 'notes.md#Work > Launch', 'notes.md#Work > Hiring', 'notes.md#Home'])
  assert.ok(chunks[1].text.includes('Priya owns pricing.'))
  assert.ok(!chunks[1].text.includes('Two roles open.'))
})

test('strips YAML frontmatter and ignores empty sections', () => {
  const md = '---\ntitle: x\ntags: [a]\n---\n# A\n\n# B\ncontent'
  const chunks = chunkMarkdown(md, 'f.md', 1000)
  assert.deepEqual(chunks.map((c) => c.source), ['f.md#B'])
  assert.ok(!chunks[0].text.includes('title: x'))
})

test('splits an oversized section on paragraph boundaries, never mid-paragraph', () => {
  const para = (n: number) => `Paragraph ${n} ` + 'word '.repeat(30).trim()
  const md = '# Big\n' + [1, 2, 3, 4, 5].map(para).join('\n\n')
  const chunks = chunkMarkdown(md, 'big.md', 400)
  assert.ok(chunks.length >= 2)
  for (const c of chunks) {
    assert.ok(c.text.length <= 400 + 200, 'chunk stays near the limit')
    assert.match(c.text.trim(), /^(# Big\n)?Paragraph \d/)
    assert.ok(c.text.trim().endsWith('word'))
  }
  assert.equal(chunks.map((c) => c.text).join(' ').match(/Paragraph \d/g)?.length, 5)
  assert.ok(chunks.every((c) => c.source.startsWith('big.md#Big')))
})

test('text without headings becomes one chunk named after the file', () => {
  const chunks = chunkMarkdown('just some plain notes', 'plain.md', 1000)
  assert.deepEqual(chunks.map((c) => c.source), ['plain.md'])
})

test('empty input yields no chunks', () => {
  assert.deepEqual(chunkMarkdown('  \n\n', 'e.md', 1000), [])
})
