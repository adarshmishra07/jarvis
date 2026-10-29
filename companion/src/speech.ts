/** Cuts a stream of text into sentences a text-to-speech voice can start on, and cleans them for speaking. */
export class SentenceSplitter {
  private buffer = ''

  /** Adds text and returns every sentence that is now complete. A period only ends a sentence when whitespace follows it. */
  push(text: string): string[] {
    this.buffer += text
    const out: string[] = []
    // End of sentence: . ! ? or the Hindi danda followed by whitespace, or any line break.
    const boundary = /([.!?।]+(?=\s)|(?<=\S)(?=\n))\s*/gu
    let start = 0
    let match: RegExpExecArray | null
    while ((match = boundary.exec(this.buffer)) !== null) {
      const end = match.index + match[1].length
      const sentence = this.buffer.slice(start, end).trim()
      if (sentence) out.push(sentence)
      start = match.index + match[0].length
      if (match[0].length === 0) boundary.lastIndex++
    }
    this.buffer = this.buffer.slice(start)
    return out
  }

  /** Returns whatever is left once the stream has ended. */
  flush(): string[] {
    const rest = this.buffer.trim()
    this.buffer = ''
    return rest ? [rest] : []
  }
}

/** Removes citation marks, markdown and link syntax so they are not read aloud. */
export function speakable(sentence: string): string {
  return sentence
    .replace(/\[w?\d+\]/g, '')
    .replace(/\[([^\]]+)\]\([^)]*\)/g, '$1')
    .replace(/^\s*([-*•]|\d+[.)])\s+/, '')
    .replace(/[*`#_|]+/g, ' ')
    .replace(/\s+([.,!?।])/g, '$1')
    .replace(/\s{2,}/g, ' ')
    .trim()
}
