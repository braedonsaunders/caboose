import { createReadStream } from 'node:fs'
import { realpath, stat } from 'node:fs/promises'
import type { IncomingMessage, ServerResponse } from 'node:http'
import { extname, resolve, sep } from 'node:path'

const types: Record<string, string> = {
  '.html': 'text/html; charset=utf-8', '.js': 'text/javascript; charset=utf-8',
  '.css': 'text/css; charset=utf-8', '.json': 'application/json', '.svg': 'image/svg+xml',
  '.png': 'image/png', '.jpg': 'image/jpeg', '.jpeg': 'image/jpeg', '.webp': 'image/webp',
  '.ico': 'image/x-icon', '.woff': 'font/woff', '.woff2': 'font/woff2',
}

/** Public compiled assets only. The caller must route every /v1 request to auth first. */
export async function serveWeb(request: IncomingMessage, response: ServerResponse, root: string, pathname: string): Promise<void> {
  const fail = (status: number): void => { response.writeHead(status, { 'cache-control': 'no-store' }); response.end() }
  if (request.method !== 'GET' && request.method !== 'HEAD') { fail(404); return }
  let decoded: string
  try { decoded = decodeURIComponent(pathname) } catch { fail(400); return }
  if (decoded.includes('\0') || decoded.includes('\\') || decoded.split('/').some(part => part.startsWith('.'))) { fail(403); return }
  try {
    const base = await realpath(root)
    let candidate = resolve(base, '.' + decoded)
    if (candidate !== base && !candidate.startsWith(base + sep)) { fail(403); return }
    if (decoded === '/') candidate = resolve(base, 'index.html')
    try { candidate = await realpath(candidate) }
    catch (error) {
      if ((error as NodeJS.ErrnoException).code !== 'ENOENT' || extname(decoded) || decoded.startsWith('/assets/')) throw error
      candidate = await realpath(resolve(base, 'index.html'))
    }
    if (!candidate.startsWith(base + sep)) { fail(403); return }
    const info = await stat(candidate)
    if (!info.isFile()) { fail(404); return }
    const extension = extname(candidate)
    response.writeHead(200, {
      'content-type': types[extension] ?? 'application/octet-stream',
      'content-length': info.size,
      'cache-control': extension === '.html' ? 'no-store' : 'public, max-age=3600',
      'x-content-type-options': 'nosniff',
      'referrer-policy': 'no-referrer',
      'x-frame-options': 'DENY',
      'content-security-policy': "default-src 'self'; script-src 'self'; style-src 'self' 'unsafe-inline'; img-src 'self' data: blob:; font-src 'self' data:; connect-src 'self'; object-src 'none'; base-uri 'self'; frame-ancestors 'none'",
    })
    if (request.method === 'HEAD') { response.end(); return }
    const stream = createReadStream(candidate)
    stream.on('error', () => response.destroy())
    response.on('close', () => stream.destroy())
    stream.pipe(response)
  } catch (error) {
    if ((error as NodeJS.ErrnoException).code === 'ENOENT' || (error as NodeJS.ErrnoException).code === 'ENOTDIR') { fail(404); return }
    throw error
  }
}
