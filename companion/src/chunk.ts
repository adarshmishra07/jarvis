export interface Chunk {
  source: string
  text: string
}

function stripFrontmatter(md: string): string {
  return md.replace(/^---\r?\n[\s\S]*?\r?\n---\r?\n?/, '')
}

function splitParagraphs(text: string, maxChars: number): string[] {
  const parts: string[] = []
  let current = ''
  for (const paragraph of text.split(/\n\s*\n/)) {
    const p = paragraph.trim()
    if (!p) continue
    if (current && current.length + p.length + 2 > maxChars) {
      parts.push(current)
      current = p
    } else {
      current = current ? `${current}\n\n${p}` : p
    }
  }
  if (current) parts.push(current)
  return parts
}

/** Splits markdown by heading, keeping the heading path as the chunk's source. Oversized sections split on paragraphs. */
export function chunkMarkdown(md: string, file: string, maxChars: number): Chunk[] {
  const body = stripFrontmatter(md)
  const path: string[] = []
  const sections: { path: string[]; lines: string[] }[] = [{ path: [], lines: [] }]

  for (const line of body.split(/\r?\n/)) {
    const heading = line.match(/^(#{1,6})\s+(.*\S)\s*$/)
    if (heading) {
      const level = heading[1].length
      path.length = level - 1
      path[level - 1] = heading[2]
      sections.push({ path: path.filter(Boolean), lines: [] })
    } else {
      sections[sections.length - 1].lines.push(line)
    }
  }

  const chunks: Chunk[] = []
  for (const section of sections) {
    const text = section.lines.join('\n').trim()
    if (!text) continue
    const source = section.path.length ? `${file}#${section.path.join(' > ')}` : file
    for (const part of splitParagraphs(text, maxChars)) chunks.push({ source, text: part })
  }
  return chunks
}
