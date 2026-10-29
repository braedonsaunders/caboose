import type { IncomingMessage, ServerResponse } from 'node:http'
import { AgentInputError } from './agents.js'

/** A route that does not exist, as opposed to one that answered. */
export const NOT_FOUND = Symbol('not found')

/** A body beyond the route's limit; answered 413. */
export class RequestTooLargeError extends Error {
  constructor(limit: number) { super(`request body too large (at most ${limit} bytes)`) }
}

export function json(response: ServerResponse, status: number, body: unknown): void {
  response.writeHead(status, { 'content-type': 'application/json', 'cache-control': 'no-store' })
  response.end(JSON.stringify(body))
}

/** A JSON object body of at most `limit` bytes. */
export function readJson(request: IncomingMessage, limit = 64 * 1024): Promise<Record<string, unknown>> {
  return new Promise((resolve, reject) => {
    const chunks: Buffer[] = []
    let size = 0
    let settled = false
    const settle = (work: () => void) => { if (!settled) { settled = true; work() } }
    const onData = (chunk: Buffer) => {
      size += chunk.length
      if (size > limit) {
        // Stop keeping the body, but let the rest of it arrive unread: destroying the
        // stream would reset the connection before the client could read its answer.
        request.off('data', onData)
        return settle(() => reject(new RequestTooLargeError(limit)))
      }
      chunks.push(chunk)
    }
    request.on('data', onData)
    request.once('error', error => settle(() => reject(error)))
    request.once('close', () => settle(() => reject(new Error('request closed before its body arrived'))))
    request.once('end', () => settle(() => {
      if (!size) return resolve({})
      try {
        const value = JSON.parse(Buffer.concat(chunks).toString('utf8'))
        if (value && typeof value === 'object' && !Array.isArray(value)) return resolve(value as Record<string, unknown>)
      } catch {}
      reject(new AgentInputError('request body must be a JSON object'))
    }))
  })
}
