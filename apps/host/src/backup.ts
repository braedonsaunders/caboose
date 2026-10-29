import { createHash, randomUUID } from 'node:crypto'
import { constants, createReadStream } from 'node:fs'
import { copyFile, lstat, mkdir, open, readdir, readFile, rename, rm, truncate, type FileHandle } from 'node:fs/promises'
import type { IncomingMessage, ServerResponse } from 'node:http'
import { join } from 'node:path'
import { AgentNotFoundError } from './agents.js'
import { baseHash, diskManifest, expandChunks, parseManifest, punchRanges, type Chunk, type DiskManifest } from './disk-helper.js'
import { json } from './http.js'
import { ComputerConflictError, type ComputerLifecycle } from './lifecycle.js'
import { SettingsInputError, writePrivateJson } from './settings.js'
import { holdParked } from './shared-storage.js'
import type { SystemImageBinding } from './system-image.js'
import type { Principal } from './server.js'

/**
 * Phone backups of a microVM computer's disk.
 *
 * A capture is a reflink clone of the coherent disk image parked Files publishes when the
 * computer parks (its filesystems frozen, its processes stopped), so it is a complete,
 * consistent filesystem without waking anything. Each capture is described by a manifest of
 * 1 MiB chunks; chunks that are zeros or identical to the computer's base image are not sent,
 * and a phone downloads only the data chunks it does not already hold, in packs.
 *
 * A restore rebuilds the disk from the base image, chunks still held by captures on this host,
 * and chunks the phone uploads; verifies the result against the manifest; and replaces the
 * computer's disk in a confirmed restart, which discards its memory like any restart.
 */

const HASH = /^[a-f0-9]{64}$/
const ID = /^[a-f0-9-]{36}$/
const PACK_CHUNKS = 32
const PACK_TTL_MS = 3 * 24 * 3_600_000
const RESTORE_TTL_MS = 24 * 3_600_000
const MAX_UPLOAD_BYTES = 256 * 1024 * 1024
const SYSTEM_FILES = ['vmlinux', 'initrd', 'system.erofs'] as const

/** What a disk needs to boot: the base its unchanged chunks come from, and for a split image its kernel, initramfs and system image. */
export interface BackupImage { baseSha256: string; system: Record<typeof SYSTEM_FILES[number], string> | null }
export interface CaptureInfo { id: string; createdAt: string; diskBytes: number; chunkBytes: number; dataChunks: number; dataBytes: number; image: BackupImage }
interface CaptureRecord { version: 1; info: CaptureInfo; manifest: DiskManifest }
interface DeviceRecord { enabledAt: string; lastCompletedAt: string | null; lastCaptureId: string | null }
interface Devices { version: 1; devices: Record<string, DeviceRecord> }
interface PackRecord { version: 1; captureId: string; chunks: string[]; expiresAt: number }
interface RestoreState { version: 1; id: string; image: BackupImage; manifest: DiskManifest; binding: SystemImageBinding | null; missing: string[]; updatedAt: number }

export interface BackupComputer {
  id: string
  lifecycle: Pick<ComputerLifecycle<unknown>, 'state' | 'subscribe' | 'parkedExclusive' | 'addParkedWorkCanceller'>
  /** Where the computer's disk lives; captures and restores stay on the same filesystem. */
  directory: string
  /** The coherent image parked Files published at the last park, if any. */
  parkedView(): Promise<{ image: string } | undefined>
  /** The computer's split image binding, or null for a disk cloned from the host's base. */
  binding(): Promise<SystemImageBinding | null>
  phoneName?(phoneId: string): string | undefined
}

export interface BackupHost {
  helper: string
  /** The host's own image directory: base.raw for computers without a split image. */
  imageRoot: string
  /** The configured split image directory, a restore target besides each computer's binding. */
  splitImage?: string
  /** Base maps and hashes, kept beside the images. */
  cacheDirectory: string
  /** Why backups cannot work on this host, or null. */
  unavailable: string | null
  /** How often a parked computer with a backup phone is captured again. */
  captureIntervalMs?: number
  now?: () => number
  /** Copy without duplicating storage; defaults to a reflink clone, which never falls back to a full copy. */
  clone?: (from: string, to: string) => Promise<void>
}

const reflink = (from: string, to: string) => copyFile(from, to, constants.COPYFILE_FICLONE_FORCE | constants.COPYFILE_EXCL)

export interface RestoreContext {
  /** Run a confirmed restart; `stage` runs inside it, after sockets close and before the computer stops. */
  restart(stage: () => Promise<void>): Promise<unknown>
  /** Install `image` as the disk (and `binding` as its image) during the next restart. */
  replaceDisk(replacement: { image: string; binding: SystemImageBinding | null }): void
}

/** Manifest computation reads whole disks: one at a time on the host. */
let manifestQueue: Promise<unknown> = Promise.resolve()
function serially<T>(work: () => Promise<T>): Promise<T> {
  const result = manifestQueue.then(work)
  manifestQueue = result.then(() => undefined, () => undefined)
  return result
}

const fileHashes = new Map<string, { key: string; sha256: string }>()
async function fileSha256(path: string): Promise<string> {
  const info = await lstat(path)
  const key = `${info.ino}:${info.size}:${info.mtimeMs}`
  const cached = fileHashes.get(path)
  if (cached?.key === key) return cached.sha256
  const hash = createHash('sha256')
  for await (const chunk of createReadStream(path)) hash.update(chunk as Buffer)
  const sha256 = hash.digest('hex')
  fileHashes.set(path, { key, sha256 })
  return sha256
}

function chunkRange(manifest: DiskManifest, index: number): [offset: number, length: number] {
  const offset = index * manifest.chunkBytes
  return [offset, Math.min(manifest.chunkBytes, manifest.diskBytes - offset)]
}

/** First chunk index of each data hash. */
function dataIndex(manifest: DiskManifest): Map<string, number[]> {
  const index = new Map<string, number[]>()
  expandChunks(manifest).forEach((chunk, at) => {
    if (chunk === 'zero' || chunk === 'base') return
    const list = index.get(chunk)
    if (list) list.push(at)
    else index.set(chunk, [at])
  })
  return index
}

async function readExactly(file: FileHandle, buffer: Buffer, position: number): Promise<void> {
  let done = 0
  while (done < buffer.length) {
    const { bytesRead } = await file.read(buffer, done, buffer.length - done, position + done)
    if (!bytesRead) { buffer.fill(0, done); return }
    done += bytesRead
  }
}

async function writeExactly(file: FileHandle, buffer: Buffer, position: number): Promise<void> {
  let done = 0
  while (done < buffer.length) done += (await file.write(buffer, done, buffer.length - done, position + done)).bytesWritten
}

async function syncDirectory(path: string): Promise<void> {
  const directory = await open(path, 'r')
  try { await directory.sync() } finally { await directory.close() }
}

function validImage(value: unknown): BackupImage {
  const image = value as BackupImage
  if (!image || typeof image !== 'object' || typeof image.baseSha256 !== 'string' || !HASH.test(image.baseSha256)) throw new SettingsInputError('Invalid backup image')
  if (image.system !== null) {
    if (!image.system || typeof image.system !== 'object' || SYSTEM_FILES.some(file => !HASH.test(String(image.system![file])))) throw new SettingsInputError('Invalid backup image')
    return { baseSha256: image.baseSha256, system: { vmlinux: image.system.vmlinux, initrd: image.system.initrd, 'system.erofs': image.system['system.erofs'] } }
  }
  return { baseSha256: image.baseSha256, system: null }
}

async function readBody(request: IncomingMessage, limit: number): Promise<Buffer> {
  const chunks: Buffer[] = []
  let size = 0
  for await (const chunk of request) {
    size += (chunk as Buffer).length
    if (size > limit) throw new SettingsInputError('request body too large')
    chunks.push(chunk as Buffer)
  }
  return Buffer.concat(chunks)
}

async function readObject(request: IncomingMessage, limit: number): Promise<Record<string, unknown>> {
  const body = await readBody(request, limit)
  if (!body.length) return {}
  try {
    const value = JSON.parse(body.toString('utf8'))
    if (value && typeof value === 'object' && !Array.isArray(value)) return value as Record<string, unknown>
  } catch {}
  throw new SettingsInputError('request body must be a JSON object')
}

export class ComputerBackups {
  private readonly root: string
  private capturing: Promise<void> | undefined
  private pending = false
  private restoring = false
  private readonly closing = new AbortController()
  private readonly unsubscribe: () => void

  constructor(private readonly host: BackupHost, private readonly computer: BackupComputer) {
    this.root = join(computer.directory, `${computer.id}.backup`)
    this.unsubscribe = computer.lifecycle.subscribe(state => { if (state === 'parked') void this.captureIfDue(false) })
  }

  private get now(): number { return this.host.now?.() ?? Date.now() }
  private path(...parts: string[]): string { return join(this.root, ...parts) }

  /** Remove incomplete captures, expired packs and abandoned restores left by a crash. */
  async open(): Promise<void> {
    if (this.host.unavailable) return
    for (const name of await readdir(this.path('captures')).catch(() => [] as string[])) {
      if (name.endsWith('.partial') || name.endsWith('.tmp')) await rm(this.path('captures', name), { force: true })
    }
    await this.prune()
    if (this.computer.lifecycle.state === 'parked') void this.captureIfDue(false)
  }

  close(): void {
    this.unsubscribe()
    this.closing.abort(new Error('The host is stopping'))
  }

  /** The computer is deleted: everything of its backups on the host goes too. */
  async destroy(): Promise<void> {
    this.close()
    await this.capturing?.catch(() => {})
    await rm(this.root, { recursive: true, force: true })
  }

  private async devices(): Promise<Devices> {
    try {
      const value = JSON.parse(await readFile(this.path('devices.json'), 'utf8')) as Devices
      if (value?.version === 1 && value.devices && typeof value.devices === 'object') return value
    } catch (error) { if ((error as NodeJS.ErrnoException).code !== 'ENOENT') throw error }
    return { version: 1, devices: {} }
  }

  private async captures(): Promise<CaptureRecord[]> {
    const records: CaptureRecord[] = []
    for (const name of await readdir(this.path('captures')).catch(() => [] as string[])) {
      if (!name.endsWith('.json')) continue
      try {
        const record = JSON.parse(await readFile(this.path('captures', name), 'utf8')) as CaptureRecord
        if (record?.version !== 1 || !ID.test(record.info?.id ?? '') || `${record.info.id}.json` !== name) continue
        await lstat(this.path('captures', `${record.info.id}.raw`))
        records.push({ version: 1, info: record.info, manifest: parseManifest(record.manifest) })
      } catch { continue }
    }
    return records.sort((a, b) => a.info.createdAt.localeCompare(b.info.createdAt))
  }

  /** Capture images, for shared storage to deduplicate alongside the disk. */
  async captureFiles(): Promise<string[]> {
    return (await this.captures()).map(record => this.path('captures', `${record.info.id}.raw`))
  }

  private async packs(): Promise<Array<{ id: string; record: PackRecord }>> {
    const packs = []
    for (const name of await readdir(this.path('packs')).catch(() => [] as string[])) {
      const id = name.replace(/\.json$/, '')
      if (!ID.test(id)) continue
      try {
        const record = JSON.parse(await readFile(this.path('packs', name), 'utf8')) as PackRecord
        if (record?.version === 1 && record.expiresAt > this.now) { packs.push({ id, record }); continue }
      } catch {}
      await rm(this.path('packs', name), { force: true })
    }
    return packs
  }

  /** Keep the newest two captures and any a phone is still downloading. */
  private async prune(): Promise<void> {
    const captures = await this.captures()
    const pinned = new Set((await this.packs()).map(pack => pack.record.captureId))
    for (const record of captures.slice(0, -2)) {
      if (pinned.has(record.info.id)) continue
      await rm(this.path('captures', `${record.info.id}.json`), { force: true })
      await rm(this.path('captures', `${record.info.id}.raw`), { force: true })
    }
    for (const name of await readdir(this.path('restores')).catch(() => [] as string[])) {
      try {
        const state = JSON.parse(await readFile(this.path('restores', name, 'state.json'), 'utf8')) as RestoreState
        if (state.updatedAt + RESTORE_TTL_MS > this.now) continue
      } catch {}
      await rm(this.path('restores', name), { recursive: true, force: true })
    }
  }

  /** Capture when a phone wants backups and the newest capture is old (or a phone asked). */
  async captureIfDue(force: boolean): Promise<void> {
    if (this.host.unavailable || this.closing.signal.aborted) return
    if (force) this.pending = true
    if (this.capturing) return this.capturing
    if (!Object.keys((await this.devices()).devices).length) return
    const newest = (await this.captures()).at(-1)
    const due = this.pending || !newest || Date.parse(newest.info.createdAt) + (this.host.captureIntervalMs ?? 6 * 3_600_000) <= this.now
    if (!due || this.computer.lifecycle.state !== 'parked') return
    this.capturing = this.capture().catch(error => {
      if (!this.closing.signal.aborted) console.error(`Could not capture a backup of ${this.computer.id}:`, error)
    }).finally(() => { this.capturing = undefined })
    return this.capturing
  }

  private async capture(): Promise<void> {
    const hold = await holdParked(this.computer.lifecycle, 5_000)
    if (!hold) return
    const id = randomUUID()
    const partial = this.path('captures', `${id}.raw.partial`)
    let binding: SystemImageBinding | null
    try {
      const view = await this.computer.parkedView()
      if (!view) return
      binding = await this.computer.binding()
      await mkdir(this.path('captures'), { recursive: true, mode: 0o700 })
      // A reflink clone: instant, and it shares every block with the disk until either changes.
      await (this.host.clone ?? reflink)(view.image, partial)
      if (hold.signal.aborted) throw hold.signal.reason
    } catch (error) {
      await rm(partial, { force: true })
      throw error
    } finally { hold.release() }
    this.pending = false
    try {
      const base = binding ? join(binding.directory, 'base.raw') : join(this.host.imageRoot, 'base.raw')
      const manifest = await serially(() => diskManifest(this.host.helper, partial, { path: base, cache: this.host.cacheDirectory }, { signal: this.closing.signal }))
      if (!manifest.baseSha256) throw new Error('The capture has no base image')
      const system = binding ? { vmlinux: binding.hashes.vmlinux, initrd: binding.hashes.initrd, 'system.erofs': binding.hashes['system.erofs'] } : null
      const chunks = expandChunks(manifest)
      const data = chunks.map((chunk, index) => [chunk, index] as const).filter(([chunk]) => chunk !== 'zero' && chunk !== 'base')
      const info: CaptureInfo = { id, createdAt: new Date(this.now).toISOString(), diskBytes: manifest.diskBytes, chunkBytes: manifest.chunkBytes,
        dataChunks: data.length, dataBytes: data.reduce((sum, [, index]) => sum + chunkRange(manifest, index)[1], 0), image: { baseSha256: manifest.baseSha256, system } }
      await rename(partial, this.path('captures', `${id}.raw`))
      await writePrivateJson(this.path('captures', `${id}.json`), { version: 1, info, manifest } satisfies CaptureRecord)
      await syncDirectory(this.path('captures'))
      await this.prune()
    } catch (error) {
      await rm(partial, { force: true })
      throw error
    }
  }

  private async findCapture(id: string): Promise<CaptureRecord> {
    if (!ID.test(id)) throw new AgentNotFoundError('backup not found')
    const record = (await this.captures()).find(candidate => candidate.info.id === id)
    if (!record) throw new AgentNotFoundError('backup not found')
    return record
  }

  async status(principal: Principal) {
    const devices = (await this.devices()).devices
    const newest = (await this.captures()).at(-1)
    return {
      available: !this.host.unavailable, ...(this.host.unavailable ? { reason: this.host.unavailable } : {}),
      enabled: principal.kind === 'phone' && principal.phoneId in devices,
      devices: Object.entries(devices).map(([id, device]) => ({ id, name: this.computer.phoneName?.(id) ?? null, lastCompletedAt: device.lastCompletedAt })),
      capture: newest?.info ?? null,
      capturing: Boolean(this.capturing),
      pending: this.pending,
    }
  }

  private async setDevice(phoneId: string, enabled: boolean): Promise<void> {
    const devices = await this.devices()
    if (enabled) devices.devices[phoneId] ??= { enabledAt: new Date(this.now).toISOString(), lastCompletedAt: null, lastCaptureId: null }
    else delete devices.devices[phoneId]
    await writePrivateJson(this.path('devices.json'), devices)
  }

  /** The phone has stored a capture in full. */
  private async complete(phoneId: string, captureId: string): Promise<void> {
    await this.findCapture(captureId)
    const devices = await this.devices()
    const device = devices.devices[phoneId]
    if (!device) throw new ComputerConflictError('This phone does not back up this computer')
    device.lastCompletedAt = new Date(this.now).toISOString()
    device.lastCaptureId = captureId
    await writePrivateJson(this.path('devices.json'), devices)
  }

  private async planPacks(captureId: string, wanted: unknown) {
    const record = await this.findCapture(captureId)
    if (!Array.isArray(wanted) || wanted.length > 1_000_000 || wanted.some(hash => typeof hash !== 'string' || !HASH.test(hash))) throw new SettingsInputError('chunks must be a list of SHA-256 hashes')
    const index = dataIndex(record.manifest)
    const unique = [...new Set(wanted as string[])]
    const unknown = unique.find(hash => !index.has(hash))
    if (unknown) throw new SettingsInputError(`The backup has no chunk ${unknown}`)
    await mkdir(this.path('packs'), { recursive: true, mode: 0o700 })
    const packs = []
    for (let at = 0; at < unique.length; at += PACK_CHUNKS) {
      const chunks = unique.slice(at, at + PACK_CHUNKS)
      const id = randomUUID()
      await writePrivateJson(this.path('packs', `${id}.json`), { version: 1, captureId, chunks, expiresAt: this.now + PACK_TTL_MS } satisfies PackRecord)
      packs.push({ id, chunks, bytes: chunks.reduce((sum, hash) => sum + chunkRange(record.manifest, index.get(hash)![0]!)[1], 0) })
    }
    return { packs }
  }

  /** A pack: its chunks' bytes, concatenated in the listed order. */
  private async sendPack(response: ServerResponse, packId: string): Promise<void> {
    if (!ID.test(packId)) throw new AgentNotFoundError('pack not found')
    const pack = (await this.packs()).find(candidate => candidate.id === packId)
    if (!pack) throw new AgentNotFoundError('pack not found')
    const record = await this.findCapture(pack.record.captureId).catch(() => { throw new ComputerConflictError('The backup this pack belongs to was replaced; start again') })
    const index = dataIndex(record.manifest)
    const ranges = pack.record.chunks.map(hash => chunkRange(record.manifest, index.get(hash)![0]!))
    const file = await open(this.path('captures', `${record.info.id}.raw`), constants.O_RDONLY | constants.O_NOFOLLOW)
    try {
      response.writeHead(200, { 'content-type': 'application/octet-stream', 'content-length': String(ranges.reduce((sum, [, length]) => sum + length, 0)), 'cache-control': 'no-store' })
      for (const [offset, length] of ranges) {
        const buffer = Buffer.allocUnsafe(length)
        await readExactly(file, buffer, offset)
        if (!response.write(buffer)) await new Promise<void>((resolve, reject) => { response.once('drain', resolve); response.once('close', () => reject(new Error('Client went away'))) })
      }
      response.end()
    } finally { await file.close() }
  }

  // Restores --------------------------------------------------------------------------

  /** A directory on this host holding exactly the image the backup was made with. */
  private async restoreTarget(image: BackupImage): Promise<{ base: string; binding: SystemImageBinding | null }> {
    const baseMatches = async (base: string) => (await baseHash(this.host.helper, base, this.host.cacheDirectory).catch(() => null))?.sha256 === image.baseSha256
    if (!image.system) {
      const base = join(this.host.imageRoot, 'base.raw')
      if (await baseMatches(base)) return { base, binding: null }
    } else {
      const current = await this.computer.binding()
      const candidates = [...new Set([current?.directory, this.host.splitImage].filter((value): value is string => Boolean(value)))]
      for (const directory of candidates) {
        const hashes = current?.directory === directory ? current.hashes : undefined
        const matches = async (file: typeof SYSTEM_FILES[number], expected: string) =>
          (hashes ? hashes[file] : await fileSha256(join(directory, file)).catch(() => null)) === expected
        if (await baseMatches(join(directory, 'base.raw')) && (await Promise.all(SYSTEM_FILES.map(file => matches(file, image.system![file])))).every(Boolean)) {
          return { base: join(directory, 'base.raw'), binding: { version: 1, directory, hashes: { 'base.raw': image.baseSha256, ...image.system } } }
        }
      }
    }
    throw new ComputerConflictError(`This backup needs the computer image it was made with (base ${image.baseSha256.slice(0, 12)}), which this host does not have`)
  }

  private async restoreState(id: string): Promise<RestoreState> {
    if (!ID.test(id)) throw new AgentNotFoundError('restore not found')
    try {
      const state = JSON.parse(await readFile(this.path('restores', id, 'state.json'), 'utf8')) as RestoreState
      if (state?.version === 1 && state.id === id) return { ...state, manifest: parseManifest(state.manifest) }
    } catch {}
    throw new AgentNotFoundError('restore not found')
  }

  /** Chunks the host already holds in a capture, by hash. */
  private async localChunks(): Promise<Map<string, { file: string; offset: number; length: number }>> {
    const local = new Map<string, { file: string; offset: number; length: number }>()
    for (const record of await this.captures()) {
      for (const [hash, indices] of dataIndex(record.manifest)) {
        const [offset, length] = chunkRange(record.manifest, indices[0]!)
        local.set(hash, { file: this.path('captures', `${record.info.id}.raw`), offset, length })
      }
    }
    return local
  }

  private async beginRestore(body: Record<string, unknown>) {
    if (this.host.unavailable) throw new ComputerConflictError(this.host.unavailable)
    const image = validImage(body.image)
    let manifest: DiskManifest
    try { manifest = parseManifest(body.manifest) } catch (error) { throw new SettingsInputError(error instanceof Error ? error.message : 'Invalid manifest') }
    if (manifest.baseSha256 !== image.baseSha256) throw new SettingsInputError('The manifest and image name different bases')
    const target = await this.restoreTarget(image)
    // Only one restore is staged at a time.
    await rm(this.path('restores'), { recursive: true, force: true })
    const id = randomUUID()
    const directory = this.path('restores', id)
    await mkdir(directory, { recursive: true, mode: 0o700 })
    const disk = join(directory, 'disk.raw')
    await (this.host.clone ?? reflink)(target.base, disk)
    await truncate(disk, manifest.diskBytes)
    const local = await this.localChunks()
    const missing = [...dataIndex(manifest).keys()].filter(hash => !local.has(hash))
    await writePrivateJson(join(directory, 'state.json'), { version: 1, id, image, manifest, binding: target.binding, missing, updatedAt: this.now } satisfies RestoreState)
    return { id, missing }
  }

  /** Chunks a phone uploads: repeated `[32-byte SHA-256][4-byte big-endian length][bytes]`. */
  private async receiveChunks(id: string, request: IncomingMessage) {
    const state = await this.restoreState(id)
    const body = await readBody(request, MAX_UPLOAD_BYTES)
    const index = dataIndex(state.manifest)
    const missing = new Set(state.missing)
    const file = await open(join(this.path('restores', id), 'disk.raw'), constants.O_RDWR | constants.O_NOFOLLOW)
    try {
      let at = 0
      while (at < body.length) {
        if (at + 36 > body.length) throw new SettingsInputError('Truncated chunk record')
        const hash = body.subarray(at, at + 32).toString('hex')
        const length = body.readUInt32BE(at + 32)
        const data = body.subarray(at + 36, at + 36 + length)
        if (data.length !== length) throw new SettingsInputError('Truncated chunk record')
        at += 36 + length
        const indices = index.get(hash)
        if (!indices) throw new SettingsInputError(`The backup has no chunk ${hash}`)
        if (createHash('sha256').update(data).digest('hex') !== hash) throw new SettingsInputError(`Chunk ${hash} does not match its hash`)
        for (const chunkIndex of indices) {
          const [offset, expected] = chunkRange(state.manifest, chunkIndex)
          if (expected !== length) throw new SettingsInputError(`Chunk ${hash} has the wrong length`)
          await writeExactly(file, data, offset)
        }
        missing.delete(hash)
      }
      await file.sync()
    } finally { await file.close() }
    state.missing = state.missing.filter(hash => missing.has(hash))
    state.updatedAt = this.now
    await writePrivateJson(join(this.path('restores', id), 'state.json'), state)
    return { id, missing: state.missing.length }
  }

  private async applyRestore(id: string, context: RestoreContext) {
    if (this.restoring) throw new ComputerConflictError('A restore is already being applied')
    this.restoring = true
    try {
      const state = await this.restoreState(id)
      if (state.missing.length) throw new ComputerConflictError(`The restore is missing ${state.missing.length} chunks; upload them first`)
      const directory = this.path('restores', id)
      const disk = join(directory, 'disk.raw')
      const target = await this.restoreTarget(state.image)
      const chunks = expandChunks(state.manifest)
      // Chunks the phone did not send come from captures on this host, each verified as copied.
      const local = await this.localChunks()
      const file = await open(disk, constants.O_RDWR | constants.O_NOFOLLOW)
      try {
        const written = new Set<string>()
        for (const [hash, indices] of dataIndex(state.manifest)) {
          const source = local.get(hash)
          if (!source || written.has(hash)) continue
          const data = Buffer.allocUnsafe(source.length)
          const from = await open(source.file, constants.O_RDONLY | constants.O_NOFOLLOW)
          try { await readExactly(from, data, source.offset) } finally { await from.close() }
          if (createHash('sha256').update(data).digest('hex') !== hash) throw new Error(`A capture's chunk ${hash} no longer matches`)
          for (const at of indices) await writeExactly(file, data, chunkRange(state.manifest, at)[0])
          written.add(hash)
        }
        await file.sync()
      } finally { await file.close() }
      const zeros: Array<[number, number]> = []
      chunks.forEach((chunk, at) => {
        if (chunk !== 'zero') return
        const [offset, length] = chunkRange(state.manifest, at)
        const last = zeros.at(-1)
        if (last && last[0] + last[1] === offset) last[1] += length
        else zeros.push([offset, length])
      })
      await punchRanges(this.host.helper, disk, zeros, { discard: true })
      // The rebuilt disk must describe exactly as the backup did.
      const rebuilt = await serially(() => diskManifest(this.host.helper, disk, { path: target.base, cache: this.host.cacheDirectory }, { chunkBytes: state.manifest.chunkBytes }))
      const expected = chunks, actual = expandChunks(rebuilt)
      if (rebuilt.diskBytes !== state.manifest.diskBytes || actual.length !== expected.length || actual.some((chunk: Chunk, at) => chunk !== expected[at])) throw new Error('The rebuilt disk does not match the backup')
      await context.restart(async () => context.replaceDisk({ image: disk, binding: target.binding }))
      await rm(directory, { recursive: true, force: true })
    } finally { this.restoring = false }
  }

  /** `/v1/backup…` for this computer. Nothing here wakes it. */
  async handle(request: IncomingMessage, response: ServerResponse, path: string, principal: Principal, context: RestoreContext): Promise<void> {
    const method = request.method
    const phone = () => {
      if (principal.kind !== 'phone') throw new SettingsInputError('Backups are kept by a signed-in phone')
      return principal.phoneId
    }
    const available = () => { if (this.host.unavailable) throw new ComputerConflictError(this.host.unavailable) }
    if (path === '/v1/backup' && method === 'GET') return json(response, 200, await this.status(principal))
    if (path === '/v1/backup/device' && method === 'PUT') {
      const body = await readObject(request, 4096)
      if (typeof body.enabled !== 'boolean' || Object.keys(body).some(key => key !== 'enabled')) throw new SettingsInputError('Send { "enabled": true } or { "enabled": false }')
      if (body.enabled) available()
      await this.setDevice(phone(), body.enabled)
      if (body.enabled && !(await this.captures()).length) void this.captureIfDue(true)
      return json(response, 200, await this.status(principal))
    }
    if (path === '/v1/backup/capture' && method === 'POST') {
      available()
      phone()
      void this.captureIfDue(true)
      return json(response, 202, await this.status(principal))
    }
    if (path === '/v1/backup/complete' && method === 'POST') {
      const body = await readObject(request, 4096)
      if (typeof body.capture !== 'string') throw new SettingsInputError('capture is required')
      await this.complete(phone(), body.capture)
      await this.prune()
      return json(response, 200, await this.status(principal))
    }
    const capture = /^\/v1\/backup\/captures\/([^/]+)(\/packs)?$/.exec(path)
    if (capture && method === 'GET' && !capture[2]) {
      const record = await this.findCapture(capture[1]!)
      return json(response, 200, { info: record.info, manifest: record.manifest })
    }
    if (capture?.[2] && method === 'POST') {
      const body = await readObject(request, 80 * 1024 * 1024)
      return json(response, 201, await this.planPacks(capture[1]!, body.chunks))
    }
    const pack = /^\/v1\/backup\/packs\/([^/]+)$/.exec(path)
    if (pack && method === 'GET') return this.sendPack(response, pack[1]!)
    if (path === '/v1/backup/restores' && method === 'POST') {
      available()
      phone()
      return json(response, 201, await this.beginRestore(await readObject(request, 32 * 1024 * 1024)))
    }
    const restore = /^\/v1\/backup\/restores\/([^/]+)(\/chunks|\/apply)?$/.exec(path)
    if (restore && !restore[2] && method === 'GET') {
      const state = await this.restoreState(restore[1]!)
      return json(response, 200, { id: state.id, missing: state.missing })
    }
    if (restore && !restore[2] && method === 'DELETE') {
      await this.restoreState(restore[1]!)
      await rm(this.path('restores', restore[1]!), { recursive: true, force: true })
      return json(response, 200, { deleted: true })
    }
    if (restore?.[2] === '/chunks' && method === 'PUT') return json(response, 200, await this.receiveChunks(restore[1]!, request))
    if (restore?.[2] === '/apply' && method === 'POST') {
      const body = await readObject(request, 4096)
      if (body.confirm !== true) throw new SettingsInputError("Restoring replaces the computer's disk and discards everything since the backup; confirm must be true")
      phone()
      await this.applyRestore(restore[1]!, context)
      return json(response, 200, await this.status(principal))
    }
    return json(response, 404, { error: 'not found' })
  }
}
