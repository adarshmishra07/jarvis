// Meaning search: multilingual-e5-small (MIT, 118 MB int8, English, Hindi and Hinglish) turns text into a vector on this
// Mac, so a question finds a note that says the same thing in other words. Nothing leaves the Mac.
import { readFileSync } from 'node:fs'
import { join } from 'node:path'
import * as ort from 'onnxruntime-node'
import { Tokenizer } from '@huggingface/tokenizers'
import type { DatabaseSync } from 'node:sqlite'
import { EMBED_MODEL, saveEmbedding, unembedded } from './db.ts'

export { EMBED_MODEL }
const MAX_TOKENS = 256 // notes are short; long ones are judged by their start

export interface Embedder { embed(texts: string[], kind: 'query' | 'passage'): Promise<Float32Array[]> }

/** Loads the model from a folder holding tokenizer.json, tokenizer_config.json and onnx/model_quantized.onnx. */
export async function loadEmbedder(dir: string): Promise<Embedder> {
  const tokenizer = new Tokenizer(JSON.parse(readFileSync(join(dir, 'tokenizer.json'), 'utf8')), JSON.parse(readFileSync(join(dir, 'tokenizer_config.json'), 'utf8')))
  const session = await ort.InferenceSession.create(join(dir, 'onnx', 'model_quantized.onnx'), { intraOpNumThreads: 2 })
  return {
    async embed(texts, kind) {
      if (!texts.length) return []
      // e5 is trained with these prefixes: questions and notes are embedded differently.
      const encoded = texts.map((t) => tokenizer.encode(`${kind}: ${t}`))
      const ids = encoded.map((e) => e.ids.slice(0, MAX_TOKENS))
      const width = Math.max(...ids.map((i) => i.length))
      const flat = (fill: (row: number[], j: number) => number): BigInt64Array =>
        BigInt64Array.from(ids.flatMap((row) => Array.from({ length: width }, (_, j) => BigInt(j < row.length ? fill(row, j) : 0))))
      const feeds: Record<string, ort.Tensor> = {
        input_ids: new ort.Tensor('int64', flat((row, j) => row[j]), [ids.length, width]),
        attention_mask: new ort.Tensor('int64', flat(() => 1), [ids.length, width]),
      }
      if (session.inputNames.includes('token_type_ids')) feeds.token_type_ids = new ort.Tensor('int64', flat(() => 0), [ids.length, width])
      const out = (await session.run(feeds))[session.outputNames[0]]
      const hidden = out.data as Float32Array
      const dims = out.dims[2]
      // Mean of the real tokens, then unit length, so a dot product is the cosine similarity.
      return ids.map((row, i) => {
        const v = new Float32Array(dims)
        for (let j = 0; j < row.length; j++) for (let d = 0; d < dims; d++) v[d] += hidden[(i * width + j) * dims + d]
        const norm = Math.hypot(...v) || 1
        return v.map((x) => x / norm)
      })
    },
  }
}

export const similarity = (a: Float32Array, b: Float32Array): number => { let s = 0; for (let i = 0; i < a.length; i++) s += a[i] * b[i]; return s }

/** Gives notes that have none a vector, a batch at a time. Returns how many were done. */
export async function embedMissing(db: DatabaseSync, embedder: Embedder, batch = 16): Promise<number> {
  const rows = unembedded(db, EMBED_MODEL, batch)
  const vectors = await embedder.embed(rows.map((r) => `${r.summary}. ${r.text}`), 'passage')
  rows.forEach((r, i) => saveEmbedding(db, r.id, vectors[i], EMBED_MODEL))
  return rows.length
}
