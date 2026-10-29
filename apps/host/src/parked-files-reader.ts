import { execFile, spawn } from 'node:child_process'
import { promisify } from 'node:util'
import type { IncomingMessage, ServerResponse } from 'node:http'
import type { ParkedFilesView } from './parked-files-store.js'
import { parkedFileIdentity } from './parked-files-metadata.js'

const exec = promisify(execFile)
const ROOT = '/home/caboose'
let slot: Promise<void> = Promise.resolve()
let queued = 0

/** Appliance output is untrusted; unsupported metadata or names wake the guest. */
export class ParkedReaderUnsupported extends Error {}
interface Stat { mode: number; uid: number; inode: bigint; size: number; mtimeNs: bigint; ctimeNs: bigint }

function pathParts(path: string): string[] {
  if (!path) return []
  const parts = path.split('/')
  if (path.startsWith('/') || parts.some(part => !/^[A-Za-z0-9_ .-]{1,200}$/.test(part) || part === '.' || part === '..' || part.startsWith('.caboose-upload-'))) throw new ParkedReaderUnsupported()
  return parts
}

function parseStat(raw: string): Stat {
  const values: Record<string, bigint> = {}
  for (const line of raw.trim().split('\n')) {
    const match = /^(st_[a-z0-9_]+): (-?\d+)$/.exec(line)
    if (!match || values[match[1]!] !== undefined) throw new ParkedReaderUnsupported()
    values[match[1]!] = BigInt(match[2]!)
  }
  for (const name of ['st_mode', 'st_uid', 'st_ino', 'st_size', 'st_mtime_sec', 'st_mtime_nsec', 'st_ctime_sec', 'st_ctime_nsec']) if (values[name] === undefined) throw new ParkedReaderUnsupported()
  const size = Number(values.st_size), mode = Number(values.st_mode), uid = Number(values.st_uid)
  if (!Number.isSafeInteger(size) || size < 0 || !Number.isSafeInteger(mode) || !Number.isSafeInteger(uid) || values.st_ino! < 0n || values.st_mtime_nsec! < 0n || values.st_mtime_nsec! >= 1_000_000_000n || values.st_ctime_nsec! < 0n || values.st_ctime_nsec! >= 1_000_000_000n) throw new ParkedReaderUnsupported()
  return { mode, uid, inode: values.st_ino!, size, mtimeNs: values.st_mtime_sec! * 1_000_000_000n + values.st_mtime_nsec!, ctimeNs: values.st_ctime_sec! * 1_000_000_000n + values.st_ctime_nsec! }
}

function metadata(name: string, stat: Stat, device: number) {
  const kind = stat.mode & 0o170000
  if (kind !== 0o040000 && kind !== 0o100000) throw new ParkedReaderUnsupported()
  // Avoid guessing guest MIME databases. Extension-bearing files wake safely.
  if (kind === 0o100000 && name.includes('.')) throw new ParkedReaderUnsupported()
  // Python's // rounds toward negative infinity, including pre-epoch dates.
  const mtime = Number(stat.mtimeNs >= 0n ? stat.mtimeNs / 1_000_000n : (stat.mtimeNs - 999_999n) / 1_000_000n)
  if (!Number.isSafeInteger(mtime)) throw new ParkedReaderUnsupported()
  return { ...parkedFileIdentity(BigInt(device), stat.inode, BigInt(stat.size), stat.mtimeNs, stat.ctimeNs), name, kind: kind === 0o040000 ? 'directory' : 'file', size: stat.size, mtime, contentType: kind === 0o040000 ? 'inode/directory' : 'application/octet-stream' }
}

function range(header: string | undefined, size: number): [number, number, boolean] {
  if (!header) return [0, size - 1, false]
  const match = /^bytes=(\d*)-(\d*)$/.exec(header)
  if (!match || (!match[1] && !match[2]) || size === 0) throw new ParkedReaderUnsupported()
  let start: number, end: number
  if (!match[1]) { const length = Number(match[2]); if (!Number.isSafeInteger(length) || length <= 0) throw new ParkedReaderUnsupported(); start = Math.max(0, size - length); end = size - 1 }
  else { start = Number(match[1]); end = match[2] ? Math.min(Number(match[2]), size - 1) : size - 1 }
  if (!Number.isSafeInteger(start) || !Number.isSafeInteger(end) || start >= size || end < start) throw new ParkedReaderUnsupported()
  return [start, end, true]
}

async function fish(view: ParkedFilesView, command: string, args: string[], deadline: number): Promise<string> {
  const remaining = deadline - Date.now()
  if (remaining <= 0) throw new ParkedReaderUnsupported()
  const result = await exec('timeout', ['--kill-after=5s', `${Math.ceil(remaining / 1000)}s`, 'guestfish', '--ro', '--format=raw', '-a', view.image, '-m', '/dev/sda', command, ...args], { timeout: remaining + 6000, maxBuffer: 1024 * 1024, env: { ...process.env, LIBGUESTFS_BACKEND: 'direct', LIBGUESTFS_MEMSIZE: '256' } })
  return result.stdout
}

async function streamContent(view: ParkedFilesView, path: string, start: number, length: number, headers: Record<string, string>, response: ServerResponse, isCurrent: () => boolean): Promise<void> {
  const child = spawn('timeout', ['--kill-after=5s', '90s', 'guestfish', '--ro', '--format=raw', '-a', view.image, '-m', '/dev/sda', 'download-offset', path, '-', String(start), String(length)], { stdio: ['ignore', 'pipe', 'ignore'], env: { ...process.env, LIBGUESTFS_BACKEND: 'direct', LIBGUESTFS_MEMSIZE: '256' } })
  let exitCode: number | null = null
  const exited = new Promise<void>(resolve => { child.once('close', code => { exitCode = code; resolve() }) })
  const cancel = () => { if (!response.writableFinished) child.kill('SIGTERM') }
  response.once('close', cancel)
  try {
    const first = await new Promise<Buffer>((resolve, reject) => {
      const cleanup = () => { child.removeListener('error', onError); child.removeListener('close', onExit); child.stdout.removeListener('data', onData) }
      const onError = (error: Error) => { cleanup(); reject(error) }
      const onExit = (code: number | null) => { cleanup(); reject(new Error(`Appliance download failed (${code})`)) }
      const onData = (data: Buffer) => { child.stdout.pause(); cleanup(); resolve(data) }
      child.once('error', onError); child.once('close', onExit); child.stdout.once('data', onData)
    })
    if (response.destroyed) { child.kill('SIGTERM'); return }
    if (!isCurrent()) throw new ParkedReaderUnsupported()
    if (first.length > length) throw new ParkedReaderUnsupported()
    response.writeHead(headers['content-range'] ? 206 : 200, headers)
    response.write(first)
    let remaining = length - first.length
    for await (const chunk of child.stdout) {
      const bytes = chunk as Buffer
      if (bytes.length > remaining) throw new Error('Appliance returned excess file bytes')
      remaining -= bytes.length
      if (!response.write(bytes)) await new Promise<void>((resolve, reject) => {
        const drained = () => { response.removeListener('close', closed); resolve() }
        const closed = () => { response.removeListener('drain', drained); reject(new Error('File client disconnected')) }
        response.once('drain', drained); response.once('close', closed)
      })
    }
    if (remaining !== 0) throw new Error('Appliance returned incomplete file bytes')
    await exited
    if (exitCode !== 0) throw new Error('Appliance download failed')
    response.end()
  } finally {
    response.removeListener('close', cancel)
    if (child.exitCode === null && child.signalCode === null) child.kill('SIGTERM')
    await exited
  }
}

async function checked(view: ParkedFilesView, parts: string[], deadline: number): Promise<Stat> {
  const root = parseStat(await fish(view, 'lstatns', ['/'], deadline))
  if ((root.mode & 0o170000) !== 0o040000 || !(root.mode & 0o001)) throw new ParkedReaderUnsupported()
  // /home must be a real directory, not a symlink to an unrelated subtree.
  const homeParent = parseStat(await fish(view, 'lstatns', ['/home'], deadline))
  if ((homeParent.mode & 0o170000) !== 0o040000 || !(homeParent.mode & 0o001)) throw new ParkedReaderUnsupported()
  let path = ROOT
  let current = parseStat(await fish(view, 'lstatns', [path], deadline))
  if (current.uid !== 1000 || (current.mode & 0o170000) !== 0o040000 || !(current.mode & 0o100)) throw new ParkedReaderUnsupported()
  for (const part of parts) {
    if ((current.mode & 0o170000) !== 0o040000 || current.uid !== 1000 || !(current.mode & 0o100)) throw new ParkedReaderUnsupported()
    path += '/' + part
    current = parseStat(await fish(view, 'lstatns', [path], deadline))
  }
  if (current.uid !== 1000) throw new ParkedReaderUnsupported()
  return current
}

/** Returns false without writing a response if the appliance cannot serve safely. */
export async function serveParkedFiles(view: ParkedFilesView, request: IncomingMessage, response: ServerResponse, isCurrent: () => boolean = () => true): Promise<boolean> {
  const url = new URL(request.url ?? '/', 'http://localhost')
  if (request.method !== 'GET' || !['/v1/fs/stat', '/v1/fs/list', '/v1/fs/content'].includes(url.pathname)) return false
  if (queued >= 16) return false
  queued++
  let release!: () => void
  const prior = slot
  slot = new Promise<void>(resolve => { release = resolve })
  await prior
  queued--
  try {
    const deadline = Date.now() + 60_000
    if (request.aborted || response.destroyed) return true
    const parts = pathParts(url.searchParams.get('path') ?? '')
    const path = ROOT + (parts.length ? '/' + parts.join('/') : '')
    const stat = await checked(view, parts, deadline)
    const name = parts.at(-1) ?? ''
    const item = metadata(name, stat, view.homeDevice)
    if (!isCurrent()) return false
    if (url.pathname === '/v1/fs/stat') {
      const body = JSON.stringify(item); response.writeHead(200, { 'content-type': 'application/json', 'content-length': Buffer.byteLength(body) }); response.end(body); return true
    }
    if (url.pathname === '/v1/fs/list') {
      if (item.kind !== 'directory' || !(stat.mode & 0o400)) return false
      const raw = await fish(view, 'readdir', [path], deadline)
      const entries = [...raw.matchAll(/^\[\d+\] = \{\n  ino: \d+\n  ftyp: [a-z?]\n  name: ([^\n]*)\n\}/gm)]
      if (raw.replace(/^\[\d+\] = \{\n  ino: \d+\n  ftyp: [a-z?]\n  name: [^\n]*\n\}\n?/gm, '').trim() || entries.length > 128) return false
      const items = []
      for (const entry of entries) {
        const child = entry[1]!
        if (child === '.' || child === '..' || child.startsWith('.caboose-upload-')) continue
        pathParts(child)
        const childStat = parseStat(await fish(view, 'lstatns', [path + '/' + child], deadline))
        if (childStat.uid !== 1000) return false
        const type = childStat.mode & 0o170000
        if (type === 0o120000 || (type !== 0o040000 && type !== 0o100000)) continue
        items.push(metadata(child, childStat, view.homeDevice))
      }
      if (!isCurrent()) return false
      const body = JSON.stringify({ items }); response.writeHead(200, { 'content-type': 'application/json', 'content-length': Buffer.byteLength(body) }); response.end(body); return true
    }
    if (item.kind !== 'file' || !(stat.mode & 0o400) || !parts.length) return false
    const match = request.headers['if-match']
    if (typeof match === 'string' && match !== '*' && match !== item.etag) {
      const body = JSON.stringify({ error: 'version mismatch' }); response.writeHead(412, { 'content-type': 'application/json', 'content-length': Buffer.byteLength(body), connection: 'close' }); response.end(body); return true
    }
    const [start, end, partial] = range(typeof request.headers.range === 'string' ? request.headers.range : undefined, stat.size)
    const length = Math.max(0, end - start + 1)
    const headers: Record<string, string> = { 'content-type': item.contentType, 'content-length': String(length), 'accept-ranges': 'bytes', etag: item.etag }
    if (partial) headers['content-range'] = `bytes ${start}-${end}/${stat.size}`
    if (!length) { response.writeHead(200, headers); response.end(); return true }
    await streamContent(view, path, start, length, headers, response, isCurrent)
    return true
  } catch (error) {
    if (response.headersSent) throw error
    return false
  } finally { release() }
}
