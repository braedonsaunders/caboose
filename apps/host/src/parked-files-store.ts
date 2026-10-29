import { randomUUID } from 'node:crypto'
import { constants } from 'node:fs'
import { lstat, open, readdir, rename, rm, rmdir, unlink } from 'node:fs/promises'
import { basename, dirname, join, resolve } from 'node:path'
import type { ParkedFreezeIntent } from './parked-files-journal.js'

type Intent = Extract<ParkedFreezeIntent, { version: 2 }>
export interface ParkedFilesView { id: string; homeDevice: number; directory: string; image: string }

async function syncDirectory(path: string): Promise<void> {
  const directory = await open(path, 'r')
  try { await directory.sync() } finally { await directory.close() }
}

/** Binds a staged clone to a completed memory-snapshot directory. Callers must
 * serialize reads with lifecycle transitions and cancel admission synchronously. */
export class ParkedFilesStore {
  private readonly pointer: string
  constructor(private readonly snapshot: string, private readonly stagingRoot: string) { this.pointer = `${snapshot}.files-view.json` }

  async publish(stage: { directory: string; image: string }, intent: Intent, snapshotDirectory: string, isCurrent: () => boolean): Promise<void> {
    if (resolve(snapshotDirectory) !== resolve(this.snapshot) || intent.homeDevice === undefined || dirname(resolve(stage.directory)) !== resolve(this.stagingRoot) || !basename(stage.directory).startsWith('.parked-files-') || resolve(stage.image) !== join(resolve(stage.directory), 'disk.raw')) throw new Error('Invalid parked Files stage')
    const rootStat = await lstat(this.stagingRoot)
    const stageStat = await lstat(stage.directory)
    const imageStat = await lstat(stage.image)
    if (!rootStat.isDirectory() || rootStat.isSymbolicLink() || (rootStat.mode & 0o077) !== 0 || (process.getuid && rootStat.uid !== process.getuid()) || !stageStat.isDirectory() || stageStat.isSymbolicLink() || (stageStat.mode & 0o077) !== 0 || !imageStat.isFile() || imageStat.isSymbolicLink()) throw new Error('Invalid parked Files stage')
    const marker = join(this.snapshot, 'files-generation')
    const temp = `${this.pointer}.${randomUUID()}.tmp`
    let markerCreated = false
    let published = false
    try {
      const markerFile = await open(marker, 'wx', 0o600)
      markerCreated = true
      try { await markerFile.writeFile(intent.id + '\n'); await markerFile.sync() } finally { await markerFile.close() }
      await syncDirectory(this.snapshot)
      const pointer = await open(temp, 'wx', 0o600)
      try { await pointer.writeFile(JSON.stringify({ version: 1, id: intent.id, homeDevice: intent.homeDevice, directory: basename(stage.directory) }) + '\n'); await pointer.sync() } finally { await pointer.close() }
      if (!isCurrent()) throw new Error('Parked Files publication cancelled')
      await rename(temp, this.pointer)
      published = true
      await syncDirectory(dirname(this.pointer))
      if (!isCurrent()) throw new Error('Parked Files publication cancelled')
    } catch (error) {
      if (published) { await unlink(this.pointer).catch(() => {}); await syncDirectory(dirname(this.pointer)).catch(() => {}) }
      if (markerCreated) await unlink(marker).catch(() => {})
      throw error
    } finally { await unlink(temp).catch(() => {}) }
  }

  async read(): Promise<ParkedFilesView | undefined> {
    let raw: string
    try {
      const file = await open(this.pointer, constants.O_RDONLY | constants.O_NOFOLLOW)
      try {
        const data = Buffer.alloc(4097)
        const { bytesRead } = await file.read(data, 0, data.length, 0)
        if (bytesRead > 4096) return undefined
        raw = data.subarray(0, bytesRead).toString('utf8')
      } finally { await file.close() }
    } catch { return undefined }
    try {
      const value: unknown = JSON.parse(raw)
      if (!value || typeof value !== 'object' || Array.isArray(value)) return undefined
      const v = value as Record<string, unknown>
      if (Object.keys(v).sort().join(',') !== 'directory,homeDevice,id,version' || v.version !== 1 || typeof v.id !== 'string' || !/^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/.test(v.id) || typeof v.homeDevice !== 'number' || !Number.isSafeInteger(v.homeDevice) || v.homeDevice < 0 || typeof v.directory !== 'string' || !/^\.parked-files-[A-Za-z0-9]+$/.test(v.directory)) return undefined
      const markerFile = await open(join(this.snapshot, 'files-generation'), constants.O_RDONLY | constants.O_NOFOLLOW)
      let marker: string
      try {
        const buffer = Buffer.alloc(65)
        const { bytesRead } = await markerFile.read(buffer, 0, buffer.length, 0)
        if (bytesRead > 64) return undefined
        marker = buffer.subarray(0, bytesRead).toString('utf8')
      } finally { await markerFile.close() }
      if (marker !== `${v.id}\n`) return undefined
      const directory = join(this.stagingRoot, v.directory), image = join(directory, 'disk.raw')
      const root = await lstat(this.stagingRoot), d = await lstat(directory), f = await lstat(image)
      if (!root.isDirectory() || root.isSymbolicLink() || (root.mode & 0o077) !== 0 || (process.getuid && root.uid !== process.getuid()) || !d.isDirectory() || d.isSymbolicLink() || (d.mode & 0o077) !== 0 || !f.isFile() || f.isSymbolicLink()) return undefined
      return { id: v.id, homeDevice: v.homeDevice, directory, image }
    } catch { return undefined }
  }

  async invalidate(): Promise<void> {
    try { await unlink(this.pointer) } catch (error) { if ((error as NodeJS.ErrnoException).code !== 'ENOENT') throw error }
    try { await syncDirectory(dirname(this.pointer)) }
    catch (error) { if ((error as NodeJS.ErrnoException).code === 'ENOENT') return; throw error }
    // This directory is dedicated to this computer's staged clones. Reap
    // incomplete stages too, including those left by a host crash.
    let root
    try { root = await lstat(this.stagingRoot) }
    catch (error) { if ((error as NodeJS.ErrnoException).code === 'ENOENT') return; throw error }
    if (!root.isDirectory() || root.isSymbolicLink() || (root.mode & 0o077) !== 0 || (process.getuid && root.uid !== process.getuid())) throw new Error('Unsafe parked Files staging directory')
    for (const entry of await readdir(this.stagingRoot, { withFileTypes: true })) {
      if (entry.isDirectory() && /^\.parked-files-[A-Za-z0-9]+$/.test(entry.name)) await rm(join(this.stagingRoot, entry.name), { recursive: true, force: true })
    }
    await syncDirectory(this.stagingRoot)
    // Remove the empty per-computer directory too. Preserve unexpected entries.
    try { await rmdir(this.stagingRoot) }
    catch (error) {
      const code = (error as NodeJS.ErrnoException).code
      if (code !== 'ENOENT' && code !== 'ENOTEMPTY') throw error
    }
  }
}
