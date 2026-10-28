import type { IncomingMessage, ServerResponse } from 'node:http'
import { AgentInputError } from './agents.js'

/** A route that does not exist, as opposed to one that answered. */
export const NOT_FOUND = Symbol('not found')

export function json(response: ServerResponse, status: number, body: unknown): void {
  response.writeHead(status, { 'content-type': 'application/json', 'cache-control': 'no-store' })
  response.end(JSON.stringify(body))
}

/** A JSON object body of at most `limit` bytes. */
export async function readJson(request: IncomingMessage, limit = 64 * 1024): Promise<Record<string, unknown>> {
  const chunks: Buffer[] = []
  let size = 0
  for await (const chunk of request) {
    size += chunk.length
    if (size > limit) throw new AgentInputError('request body too large')
    chunks.push(chunk as Buffer)
  }
  if (!size) return {}
  try {
    const value = JSON.parse(Buffer.concat(chunks).toString('utf8'))
    if (value && typeof value === 'object' && !Array.isArray(value)) return value as Record<string, unknown>
  } catch {}
  throw new AgentInputError('request body must be a JSON object')
}
