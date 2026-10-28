import { request as httpRequest } from 'node:http'
import type { IncomingMessage, ServerResponse } from 'node:http'
import { pipeline } from 'node:stream/promises'

export interface FileService { url: string; token: string }

/** Relay one request without buffering the file; the caller holds the lifecycle lease. */
export async function proxyFiles(service: FileService, input: IncomingMessage, output: ServerResponse): Promise<void> {
  const url = new URL(input.url ?? '/', service.url)
  url.pathname = url.pathname.slice('/v1/fs'.length) || '/'
  const headers: Record<string, string> = { authorization: `Bearer ${service.token}` }
  for (const name of ['content-type', 'content-length', 'range', 'if-match', 'if-none-match']) {
    const value = input.headers[name]
    if (typeof value === 'string') headers[name] = value
  }
  await new Promise<void>((resolve, reject) => {
    const upstream = httpRequest(url, { method: input.method, headers }, response => {
      const forwarded: Record<string, string> = {}
      for (const name of ['content-type', 'content-length', 'content-range', 'accept-ranges', 'etag']) {
        const value = response.headers[name]
        if (typeof value === 'string') forwarded[name] = value
      }
      output.writeHead(response.statusCode ?? 502, forwarded)
      pipeline(response, output).then(resolve, reject)
    })
    upstream.on('error', reject)
    output.once('close', () => { if (!output.writableFinished) upstream.destroy() })
    input.once('aborted', () => upstream.destroy())
    input.pipe(upstream)
  })
}
