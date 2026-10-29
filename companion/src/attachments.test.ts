import { test } from 'node:test'
import assert from 'node:assert/strict'
import { execFileSync } from 'node:child_process'
import { mkdtempSync, readFileSync, writeFileSync, mkdirSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { toBlocks } from './attachments.ts'

const b64 = (s: string | Buffer): string => Buffer.from(s).toString('base64')

test('images and PDFs go to the model as they are; text files as text documents', async () => {
  const r = await toBlocks([
    { name: 'shot.png', data: b64(Buffer.concat([Buffer.from([0x89, 0x50, 0x4e, 0x47]), Buffer.from('png-bytes')])) },
    { name: 'deck.pdf', data: b64('%PDF-1.4 bytes') },
    { name: 'notes.md', data: b64('# Orbit\nShip Friday') },
  ])
  assert.deepEqual(r.map((x) => x.type), ['image', 'document', 'document'])
  assert.equal((r[0] as any).source.media_type, 'image/png')
  assert.equal((r[1] as any).source.media_type, 'application/pdf')
  assert.equal((r[2] as any).source.data, '# Orbit\nShip Friday')
  assert.equal((r[2] as any).title, 'notes.md')
})

test('Word files are read with macOS textutil', async () => {
  const dir = mkdtempSync(join(tmpdir(), 'att-'))
  writeFileSync(join(dir, 'a.txt'), 'Quarterly plan: hire two engineers.')
  execFileSync('textutil', ['-convert', 'docx', join(dir, 'a.txt'), '-output', join(dir, 'a.docx')])
  const [doc] = await toBlocks([{ name: 'plan.docx', data: readFileSync(join(dir, 'a.docx')).toString('base64') }])
  assert.match((doc as any).source.data, /hire two engineers/)
})

test('Excel sheets and PowerPoint slides give their text', async () => {
  const dir = mkdtempSync(join(tmpdir(), 'att-'))
  mkdirSync(join(dir, 'x', 'xl', 'worksheets'), { recursive: true })
  writeFileSync(join(dir, 'x', 'xl', 'sharedStrings.xml'), '<sst><si><t>Revenue</t></si><si><t>Q1</t></si></sst>')
  writeFileSync(join(dir, 'x', 'xl', 'worksheets', 'sheet1.xml'), '<worksheet><sheetData><row r="1"><c r="A1" t="s"><v>1</v></c><c r="B1" t="s"><v>0</v></c></row><row r="2"><c r="A2"><v>42</v></c></row></sheetData></worksheet>')
  execFileSync('zip', ['-qr', join(dir, 'book.xlsx'), 'xl'], { cwd: join(dir, 'x') })
  mkdirSync(join(dir, 'p', 'ppt', 'slides'), { recursive: true })
  writeFileSync(join(dir, 'p', 'ppt', 'slides', 'slide1.xml'), '<p:sld><a:t>Orbit launch</a:t><a:t>14 November</a:t></p:sld>')
  execFileSync('zip', ['-qr', join(dir, 'deck.pptx'), 'ppt'], { cwd: join(dir, 'p') })
  const [sheet, slides] = await toBlocks([
    { name: 'book.xlsx', data: readFileSync(join(dir, 'book.xlsx')).toString('base64') },
    { name: 'deck.pptx', data: readFileSync(join(dir, 'deck.pptx')).toString('base64') },
  ])
  assert.match((sheet as any).source.data, /Q1\tRevenue\n42/)
  assert.match((slides as any).source.data, /Slide 1: Orbit launch 14 November/)
})

test('a transcript the app made arrives as a text document', async () => {
  const [t] = await toBlocks([{ name: 'call.m4a', data: b64('We agreed to ship Friday.'), transcript: true }])
  assert.equal((t as any).source.data, 'We agreed to ship Friday.')
  assert.equal((t as any).title, 'call.m4a (transcript)')
})

test('unreadable or oversized files become a short note, never a failure', async () => {
  const r = await toBlocks([
    { name: 'tool.bin', data: b64(Buffer.from([0, 1, 2, 0, 255])) },
    { name: 'huge.png', data: b64(Buffer.concat([Buffer.from([0x89, 0x50, 0x4e, 0x47]), Buffer.alloc(6_000_000)])) },
  ])
  assert.deepEqual(r.map((x) => x.type), ['text', 'text'])
  assert.match((r[0] as any).text, /tool\.bin.*cannot be read/)
  assert.match((r[1] as any).text, /huge\.png.*too large/)
})

test('HTML is read without fetching anything: tags and scripts are stripped here', async () => {
  const [doc] = await toBlocks([{ name: 'page.html', data: b64('<html><head><script>steal()</script><style>p{}</style></head><body><p>Launch &amp; ship</p><img src="https://x.example/t.png"></body></html>') }])
  assert.equal((doc as any).source.data.trim(), 'Launch & ship')
})

test('the picture type comes from the bytes, not the name; oversized pictures and PDFs become a note', async () => {
  const jpeg = Buffer.concat([Buffer.from([0xff, 0xd8, 0xff, 0xe0]), Buffer.alloc(100)])
  const [img] = await toBlocks([{ name: 'photo.png', data: jpeg.toString('base64') }])
  assert.equal((img as any).source.media_type, 'image/jpeg')
  const big = await toBlocks([
    { name: 'big.png', data: Buffer.concat([Buffer.from([0x89, 0x50, 0x4e, 0x47]), Buffer.alloc(4_000_000)]).toString('base64') },
    { name: 'huge.pdf', data: Buffer.concat([Buffer.from('%PDF-1.4'), Buffer.alloc(21_000_000)]).toString('base64') },
  ])
  assert.deepEqual(big.map((b) => b.type), ['text', 'text'])
})

test('spreadsheet cells keep their place even when some are empty and self-closing', async () => {
  const dir = mkdtempSync(join(tmpdir(), 'att-'))
  mkdirSync(join(dir, 'x', 'xl', 'worksheets'), { recursive: true })
  writeFileSync(join(dir, 'x', 'xl', 'sharedStrings.xml'), '<sst><si><t>Name</t></si></sst>')
  writeFileSync(join(dir, 'x', 'xl', 'worksheets', 'sheet1.xml'), '<worksheet><sheetData><row r="1"><c r="A1" s="1"/><c r="B1" t="s"><v>0</v></c></row></sheetData></worksheet>')
  execFileSync('zip', ['-qr', join(dir, 'b.xlsx'), 'xl'], { cwd: join(dir, 'x') })
  const [sheet] = await toBlocks([{ name: 'b.xlsx', data: readFileSync(join(dir, 'b.xlsx')).toString('base64') }])
  assert.equal((sheet as any).source.data, '\tName')
})
