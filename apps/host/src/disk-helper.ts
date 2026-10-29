import { spawn, type ChildProcessWithoutNullStreams } from 'node:child_process'
import { createInterface } from 'node:readline'

/** `caboose-disk` (apps/host/disk): shared storage passes, backup manifests and hole punching. */

export interface DedupeSource { key: string; path: string; immutable?: boolean }
export interface DedupeJob {
  /** `computer:<id>`: the disk being deduplicated. */
  key: string
  /** The disk first, then the clones that track it (a parked Files view, backup captures). */
  files: string[]
  sources: DedupeSource[]
  /** Every key still in use; the helper forgets the rest. */
  live?: string[]
}
export interface DedupeReport { hashedBytes: number; sharedBytes: number; punchedBytes: number; skippedSources: string[] }
export type DedupeResult =
  | { ok: true; report: DedupeReport }
  | { ok: false; error: 'busy' | 'missing' | 'cancelled' | 'unsupported' | 'io' | 'invalid'; message?: string; report?: DedupeReport }

type Spawn = (command: string, args: string[]) => ChildProcessWithoutNullStreams

const KEY = /^[A-Za-z0-9:._-]{1,160}$/

/**
 * One long-lived `caboose-disk dedupe-serve` holding the index in memory. Requests run one at
 * a time; aborting a request's signal cancels it between kernel calls. The process exits
 * after `idleMs` without requests and is started again on the next.
 */
export class DedupeHelper {
  private child: ChildProcessWithoutNullStreams | undefined
  private ready: Promise<void> | undefined
  private pending = new Map<number, (reply: Record<string, unknown>) => void>()
  private sequence = 0
  private queue: Promise<unknown> = Promise.resolve()
  private idle: ReturnType<typeof setTimeout> | undefined

  constructor(private readonly binary: string, private readonly stateDirectory: string, private readonly options: { idleMs?: number; spawn?: Spawn } = {}) {}

  run(job: DedupeJob, signal: AbortSignal): Promise<DedupeResult> {
    if (!KEY.test(job.key) || job.sources.some(source => !KEY.test(source.key)) || job.live?.some(key => !KEY.test(key))) throw new Error('Invalid dedupe key')
    return this.enqueue(async () => {
      if (signal.aborted) return { ok: false, error: 'cancelled' } as const
      const reply = await this.request({ op: 'run', ...job }, signal)
      return parseResult(reply)
    })
  }

  forget(key: string): Promise<void> {
    if (!KEY.test(key)) throw new Error('Invalid dedupe key')
    return this.enqueue(async () => {
      const reply = await this.request({ op: 'forget', key })
      if (reply.ok !== true) throw new Error(`Could not forget ${key}: ${String(reply.message ?? reply.error)}`)
    })
  }

  async close(): Promise<void> {
    if (this.idle) clearTimeout(this.idle)
    const child = this.child
    if (!child) return
    await new Promise<void>(resolve => {
      child.once('close', () => resolve())
      child.stdin.end()
      setTimeout(() => child.kill('SIGKILL'), 10_000).unref()
    })
  }

  private enqueue<T>(work: () => Promise<T>): Promise<T> {
    const result = this.queue.then(work)
    this.queue = result.then(() => undefined, () => undefined)
    return result
  }

  private start(): Promise<void> {
    if (this.ready) return this.ready
    const spawnHelper = this.options.spawn ?? ((command, args) => spawn(command, args, { stdio: ['pipe', 'pipe', 'pipe'] }))
    const child = spawnHelper(this.binary, ['dedupe-serve', '--state', this.stateDirectory])
    this.child = child
    this.ready = new Promise((resolve, reject) => {
      let started = false
      let stderr = ''
      child.stderr.setEncoding('utf8')
      child.stderr.on('data', (chunk: string) => { stderr = (stderr + chunk).slice(-2000) })
      child.once('error', error => { if (!started) reject(error) })
      createInterface({ input: child.stdout }).on('line', line => {
        let reply: Record<string, unknown>
        try { reply = JSON.parse(line) as Record<string, unknown> } catch { return }
        if (!started && reply.ready === true) { started = true; resolve(); return }
        const id = typeof reply.id === 'number' ? reply.id : -1
        const settle = this.pending.get(id)
        if (settle) { this.pending.delete(id); settle(reply) }
      })
      child.once('close', code => {
        if (!started) reject(new Error(`caboose-disk exited (${code}): ${stderr.trim()}`))
        for (const settle of this.pending.values()) settle({ ok: false, error: 'io', message: `caboose-disk exited (${code}): ${stderr.trim()}` })
        this.pending.clear()
        if (this.child === child) { this.child = undefined; this.ready = undefined }
      })
    })
    this.ready.catch(() => { this.ready = undefined; this.child = undefined })
    return this.ready
  }

  private async request(command: Record<string, unknown>, signal?: AbortSignal): Promise<Record<string, unknown>> {
    if (this.idle) clearTimeout(this.idle)
    await this.start()
    const child = this.child!
    const id = ++this.sequence
    const reply = new Promise<Record<string, unknown>>(resolve => this.pending.set(id, resolve))
    const cancel = () => { if (!child.stdin.destroyed) child.stdin.write(`${JSON.stringify({ op: 'cancel', id })}\n`) }
    signal?.addEventListener('abort', cancel, { once: true })
    child.stdin.write(`${JSON.stringify({ ...command, id })}\n`)
    try { return await reply } finally {
      signal?.removeEventListener('abort', cancel)
      this.idle = setTimeout(() => { void this.close() }, this.options.idleMs ?? 300_000)
      this.idle.unref()
    }
  }
}

function parseResult(reply: Record<string, unknown>): DedupeResult {
  const report = reply.report as DedupeReport | undefined
  if (reply.ok === true && report) return { ok: true, report }
  const errors = ['busy', 'missing', 'cancelled', 'unsupported', 'io', 'invalid'] as const
  const error = errors.find(kind => kind === reply.error) ?? 'io'
  return { ok: false, error, ...(typeof reply.message === 'string' ? { message: reply.message } : {}), ...(report ? { report } : {}) }
}

/** A manifest entry: one data chunk's SHA-256, or a run of zero or base chunks. */
export type ManifestEntry = string | { zero: number } | { base: number }
export interface DiskManifest { version: 1; diskBytes: number; chunkBytes: number; baseSha256: string | null; chunks: ManifestEntry[] }
export type Chunk = 'zero' | 'base' | string

const HASH = /^[a-f0-9]{64}$/
export const MAX_DISK_BYTES = 16 * 1024 ** 4

/** Validate a manifest from the helper or from a phone. */
export function parseManifest(value: unknown): DiskManifest {
  const m = value as DiskManifest
  if (!m || typeof m !== 'object' || m.version !== 1) throw new Error('Unsupported backup manifest')
  if (!Number.isSafeInteger(m.chunkBytes) || m.chunkBytes < 4096 || m.chunkBytes > 64 * 1024 ** 2 || (m.chunkBytes & (m.chunkBytes - 1)) !== 0) throw new Error('Invalid manifest chunk size')
  if (!Number.isSafeInteger(m.diskBytes) || m.diskBytes < 1 || m.diskBytes > MAX_DISK_BYTES || m.diskBytes % 4096 !== 0) throw new Error('Invalid manifest disk size')
  if (m.baseSha256 !== null && (typeof m.baseSha256 !== 'string' || !HASH.test(m.baseSha256))) throw new Error('Invalid manifest base')
  if (!Array.isArray(m.chunks)) throw new Error('Invalid manifest chunks')
  let count = 0
  for (const entry of m.chunks) {
    if (typeof entry === 'string') {
      if (!HASH.test(entry)) throw new Error('Invalid manifest chunk')
      count++
      continue
    }
    const keys = entry && typeof entry === 'object' ? Object.keys(entry) : []
    const run = keys.length === 1 && (keys[0] === 'zero' || keys[0] === 'base') ? (entry as Record<string, number>)[keys[0]!] : undefined
    if (!Number.isSafeInteger(run) || run! < 1) throw new Error('Invalid manifest run')
    if (keys[0] === 'base' && m.baseSha256 === null) throw new Error('Manifest names base chunks without a base')
    count += run!
  }
  if (count !== Math.ceil(m.diskBytes / m.chunkBytes)) throw new Error('Manifest chunks do not cover the disk')
  return { version: 1, diskBytes: m.diskBytes, chunkBytes: m.chunkBytes, baseSha256: m.baseSha256, chunks: m.chunks }
}

/** One entry per chunk. */
export function expandChunks(manifest: DiskManifest): Chunk[] {
  const chunks: Chunk[] = []
  for (const entry of manifest.chunks) {
    if (typeof entry === 'string') chunks.push(entry)
    else if ('zero' in entry) for (let i = 0; i < entry.zero; i++) chunks.push('zero')
    else for (let i = 0; i < entry.base; i++) chunks.push('base')
  }
  return chunks
}

function runHelper(binary: string, args: string[], input: string | undefined, signal: AbortSignal | undefined, spawnHelper: Spawn | undefined): Promise<string> {
  return new Promise((resolve, reject) => {
    const child = (spawnHelper ?? ((command, argv) => spawn(command, argv, { stdio: ['pipe', 'pipe', 'pipe'] })))(binary, args)
    const out: Buffer[] = []
    let stderr = ''
    const abort = () => child.kill('SIGTERM')
    signal?.addEventListener('abort', abort, { once: true })
    child.stdout.on('data', (chunk: Buffer) => out.push(chunk))
    child.stderr.setEncoding('utf8')
    child.stderr.on('data', (chunk: string) => { stderr = (stderr + chunk).slice(-2000) })
    child.once('error', reject)
    child.once('close', code => {
      signal?.removeEventListener('abort', abort)
      if (signal?.aborted) reject(signal.reason instanceof Error ? signal.reason : new Error('Cancelled'))
      else if (code === 0) resolve(Buffer.concat(out).toString('utf8'))
      else reject(new Error(stderr.trim().replace(/^caboose-disk: /, '') || `caboose-disk exited with ${code}`))
    })
    child.stdin.end(input)
  })
}

/** The manifest of an image that does not change while it is read (a backup capture). */
export async function diskManifest(binary: string, image: string, base: { path: string; cache: string } | null, options: { signal?: AbortSignal; chunkBytes?: number; spawn?: Spawn } = {}): Promise<DiskManifest> {
  const args = ['manifest', '--image', image, ...(base ? ['--base', base.path, '--cache', base.cache] : []), ...(options.chunkBytes ? ['--chunk-bytes', String(options.chunkBytes)] : [])]
  return parseManifest(JSON.parse(await runHelper(binary, args, undefined, options.signal, options.spawn)))
}

/** Deallocate ranges of a file the caller owns. `discard` drops data; otherwise every range must read as zeros. */
export async function punchRanges(binary: string, file: string, ranges: Array<[offset: number, length: number]>, options: { discard?: boolean; spawn?: Spawn } = {}): Promise<void> {
  if (!ranges.length) return
  await runHelper(binary, [options.discard ? 'discard' : 'punch', file], ranges.map(([offset, length]) => `${offset} ${length}\n`).join(''), undefined, options.spawn)
}
