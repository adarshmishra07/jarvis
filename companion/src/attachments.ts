import { execFile } from 'node:child_process'
import { mkdtemp, rm, writeFile } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { extname, join } from 'node:path'
import { promisify } from 'node:util'

// Files attached to a question, turned into what the model reads: images and PDFs as they are, everything else as text.
// Office files are read with tools macOS already has (textutil, unzip). Audio and video arrive as transcripts the app
// made on this Mac. Files are data the user shared, never instructions.

const run = promisify(execFile)

export interface Attachment { name: string; data: string; transcript?: boolean }
type Block = Record<string, unknown> & { type: string }

const IMAGE_TYPES: Record<string, string> = { '.png': 'image/png', '.jpg': 'image/jpeg', '.jpeg': 'image/jpeg', '.gif': 'image/gif', '.webp': 'image/webp' }
/** Formats that cannot point at outside resources. HTML is stripped here instead, so nothing is ever fetched. */
const TEXTUTIL = new Set(['.doc', '.docx', '.rtf', '.odt', '.wordml'])
const HTML = new Set(['.html', '.htm', '.xhtml'])
/** Under the model's own limits once base64-encoded (5 MB per image; about 32 MB per request). */
const MAX_IMAGE_BYTES = 3_700_000
const MAX_PDF_BYTES = 20_000_000
const MAX_FILE_BYTES = 30_000_000

/** The picture's real type from its first bytes; the name can be wrong. */
function imageType(bytes: Buffer): string | null {
  if (bytes[0] === 0xff && bytes[1] === 0xd8 && bytes[2] === 0xff) return 'image/jpeg'
  if (bytes.subarray(0, 4).toString('hex') === '89504e47') return 'image/png'
  if (bytes.subarray(0, 3).toString('ascii') === 'GIF') return 'image/gif'
  if (bytes.subarray(0, 4).toString('ascii') === 'RIFF' && bytes.subarray(8, 12).toString('ascii') === 'WEBP') return 'image/webp'
  return null
}
const MAX_TEXT_CHARS = 150_000
const TOOL_TIMEOUT_MS = 20_000

const note = (text: string): Block => ({ type: 'text', text: `[${text}]` })
const textDoc = (title: string, text: string): Block =>
  ({ type: 'document', title, source: { type: 'text', media_type: 'text/plain', data: text.slice(0, MAX_TEXT_CHARS) } })
const clean = (name: string): string => name.replace(/[^\p{L}\p{N} ._()-]/gu, '').slice(0, 120) || 'file'

/** Runs a macOS tool on the file, written to a private temporary folder that is removed afterwards. */
async function withFile<T>(name: string, bytes: Buffer, use: (path: string) => Promise<T>): Promise<T> {
  const dir = await mkdtemp(join(tmpdir(), 'pikachu-file-'))
  try {
    const path = join(dir, `file${extname(name).toLowerCase()}`)
    await writeFile(path, bytes, { mode: 0o600 })
    return await use(path)
  } finally { await rm(dir, { recursive: true, force: true }) }
}

const unzip = async (path: string, ...parts: string[]): Promise<string> =>
  (await run('unzip', ['-p', path, ...parts], { timeout: TOOL_TIMEOUT_MS, maxBuffer: 50_000_000 }).catch(() => ({ stdout: '' }))).stdout
const unescape = (s: string): string => s.replace(/&lt;/g, '<').replace(/&gt;/g, '>').replace(/&quot;/g, '"').replace(/&apos;/g, "'").replace(/&amp;/g, '&')

/** Rows of every sheet, cells separated by tabs, with shared strings filled in. */
async function sheetText(path: string): Promise<string> {
  const strings = [...(await unzip(path, 'xl/sharedStrings.xml')).matchAll(/<si>([\s\S]*?)<\/si>/g)]
    .map((m) => unescape([...m[1].matchAll(/<t[^>]*>([\s\S]*?)<\/t>/g)].map((t) => t[1]).join('')))
  const sheets = await unzip(path, 'xl/worksheets/*.xml')
  return [...sheets.matchAll(/<row[^>]*>([\s\S]*?)<\/row>/g)].map((row) =>
    // A cell is either <c .../> (empty) or <c ...>...</c>; matching both keeps every column in its place.
    [...row[1].matchAll(/<c((?:\s[^>]*?)?)(?:\/>|>([\s\S]*?)<\/c>)/g)].map(([, attrs, body = '']) => {
      const v = body.match(/<v>([\s\S]*?)<\/v>/)?.[1] ?? body.match(/<t[^>]*>([\s\S]*?)<\/t>/)?.[1] ?? ''
      return /t="s"/.test(attrs) ? strings[Number(v)] ?? '' : unescape(v)
    }).join('\t')).join('\n')
}

/** The text of each slide, in order. */
async function slideText(path: string): Promise<string> {
  const listing = (await run('unzip', ['-Z1', path], { timeout: TOOL_TIMEOUT_MS }).catch(() => ({ stdout: '' }))).stdout
  const slides = listing.split('\n').filter((f) => /^ppt\/slides\/slide\d+\.xml$/.test(f)).sort((a, b) => Number(a.match(/\d+/)![0]) - Number(b.match(/\d+/)![0]))
  const out: string[] = []
  for (const [i, s] of slides.entries()) out.push(`Slide ${i + 1}: ${[...(await unzip(path, s)).matchAll(/<a:t>([\s\S]*?)<\/a:t>/g)].map((m) => unescape(m[1])).join(' ')}`)
  return out.join('\n')
}

/** The visible text of a web page, without scripts, styles or tags. */
const htmlText = (html: string): string => unescape(html.replace(/<(script|style)[\s\S]*?<\/\1>/gi, ' ').replace(/<br\s*\/?>|<\/(p|div|li|h\d|tr)>/gi, '\n')
  .replace(/<[^>]+>/g, ' ')).replace(/&nbsp;/g, ' ').replace(/[ \t]+/g, ' ').replace(/\n\s*\n+/g, '\n').trim()

/** Plain text when the bytes are text (no NUL bytes and valid UTF-8), else null. */
function asText(bytes: Buffer): string | null {
  if (bytes.includes(0)) return null
  const text = new TextDecoder('utf-8', { fatal: false }).decode(bytes)
  return text.includes('�') ? null : text
}

async function one(file: Attachment): Promise<Block> {
  const name = clean(file.name)
  const bytes = Buffer.from(file.data, 'base64')
  if (bytes.length > MAX_FILE_BYTES) return note(`${name} is too large to read (over 30 MB)`)
  if (file.transcript) return textDoc(`${name} (transcript)`, bytes.toString('utf8'))
  const ext = extname(name).toLowerCase()
  if (IMAGE_TYPES[ext]) {
    const type = imageType(bytes)
    if (!type) return note(`${name} cannot be read: it is not a PNG, JPEG, GIF or WebP picture`)
    if (bytes.length > MAX_IMAGE_BYTES) return note(`${name} is too large to look at (pictures up to about 3.5 MB)`)
    return { type: 'image', source: { type: 'base64', media_type: type, data: file.data } }
  }
  if (ext === '.pdf') {
    if (bytes.length > MAX_PDF_BYTES) return note(`${name} is too large to read (PDFs up to 20 MB)`)
    return { type: 'document', title: name, source: { type: 'base64', media_type: 'application/pdf', data: file.data } }
  }
  const extracted = TEXTUTIL.has(ext) ? await withFile(name, bytes, async (p) => (await run('textutil', ['-convert', 'txt', '-stdout', p], { timeout: TOOL_TIMEOUT_MS, maxBuffer: 50_000_000 })).stdout).catch(() => '')
    : HTML.has(ext) ? htmlText(asText(bytes) ?? '')
    : ext === '.xlsx' ? await withFile(name, bytes, sheetText)
    : ext === '.pptx' ? await withFile(name, bytes, slideText)
    : asText(bytes)
  return extracted?.trim() ? textDoc(name, extracted) : note(`${name} cannot be read: this kind of file is not supported yet`)
}

/** Content blocks for the user's message, in the order attached. One bad file never fails the rest. */
export async function toBlocks(files: Attachment[]): Promise<Block[]> {
  return Promise.all(files.map((f) => one(f).catch(() => note(`${clean(f.name)} cannot be read`))))
}
