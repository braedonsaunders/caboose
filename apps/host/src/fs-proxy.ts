import { request as httpRequest } from 'node:http'
import type { IncomingMessage, ServerResponse } from 'node:http'
import { pipeline } from 'node:stream/promises'

export interface FileService { url: string; token: string }

const IDLE_TIMEOUT_MS = 60_000

/** Relay one request without buffering the file; the caller holds the lifecycle lease. */
export async function proxyFiles(service: FileService, input: IncomingMessage, output: ServerResponse, idleTimeoutMs = IDLE_TIMEOUT_MS): Promise<void> {
  // The request may have waited behind a wake or another lifecycle operation.
  if (input.aborted || output.destroyed) return
  const url = new URL(input.url ?? '/', service.url)
  url.pathname = url.pathname.slice('/v1/fs'.length) || '/'
  const headers: Record<string, string> = { authorization: `Bearer ${service.token}` }
  for (const name of ['content-type', 'content-length', 'range', 'if-match', 'if-none-match']) {
    const value = input.headers[name]
    if (typeof value === 'string') headers[name] = value
  }
  await new Promise<void>((resolve, reject) => {
    let settled = false
    let guestResponse: IncomingMessage | undefined
    let timer: ReturnType<typeof setTimeout>
    const cleanup = () => {
      clearTimeout(timer)
      input.removeListener('aborted', cancel)
      input.removeListener('data', progress)
      output.removeListener('close', onClose)
      output.removeListener('drain', progress)
      guestResponse?.removeListener('data', progress)
    }
    const finish = (error?: Error) => {
      if (settled) return
      settled = true
      cleanup()
      input.unpipe(upstream)
      if (error) reject(error)
      else resolve()
    }
    const cancel = () => {
      upstream.destroy()
      guestResponse?.destroy()
      finish()
    }
    const onClose = () => { if (!output.writableFinished) cancel() }
    const progress = () => { timer.refresh() }
    const upstream = httpRequest(url, { method: input.method, headers }, response => {
      guestResponse = response
      response.on('data', progress)
      const forwarded: Record<string, string> = {}
      for (const name of ['content-type', 'content-length', 'content-range', 'accept-ranges', 'etag']) {
        const value = response.headers[name]
        if (typeof value === 'string') forwarded[name] = value
      }
      output.writeHead(response.statusCode ?? 502, forwarded)
      pipeline(response, output).then(() => finish(), error => finish(error))
    })
    upstream.on('error', error => finish(error))
    upstream.on('close', () => { if (!guestResponse && !settled) finish(new Error('File service connection closed')) })
    timer = setTimeout(() => {
      upstream.destroy()
      guestResponse?.destroy()
      if (!output.headersSent && !output.destroyed) {
        output.writeHead(504, { connection: 'close' })
        output.end()
      } else if (!output.destroyed) output.destroy()
      finish()
    }, idleTimeoutMs)
    timer.unref()
    output.once('close', onClose)
    output.on('drain', progress)
    input.once('aborted', cancel)
    input.on('data', progress)
    input.pipe(upstream)
  })
}
