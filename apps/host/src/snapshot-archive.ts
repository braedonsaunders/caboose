import { createCipheriv, createDecipheriv, createHash, randomBytes, randomUUID } from 'node:crypto'
import { constants } from 'node:fs'
import { mkdir, open, readdir, rm } from 'node:fs/promises'
import { basename, join } from 'node:path'
import { PassThrough, Readable, Transform, Writable } from 'node:stream'
import { pipeline } from 'node:stream/promises'
import { createGunzip, createGzip } from 'node:zlib'

/** Object keys are private and immutable; publication is owned by the lifecycle. */
export interface SnapshotObjectStore {
  putStream(input: { key: string; body: AsyncIterable<Uint8Array>; signal?: AbortSignal }): Promise<void>
  getStream(key: string, options?: { signal?: AbortSignal }): Promise<{ stream: ReadableStream }>
  delete(key: string, options?: { signal?: AbortSignal }): Promise<void>
}
export interface SnapshotArchiveEntry {
  name: string
  key: string
  nonce: string
  tag: string
  sha256: string
  sourceSha256: string
  size: number
}
export interface SnapshotArchive {
  version: 1
  id: string
  entries: SnapshotArchiveEntry[]
}

function validName(name: string): boolean {
  return /^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$/.test(name) && name !== '.' && name !== '..'
}
function checkKey(key: Uint8Array): void {
  if (key.byteLength !== 32) throw new Error('Snapshot archive key must be 32 bytes')
}
const zeroBlock = Buffer.alloc(64 * 1024)
function allZero(bytes: Buffer): boolean {
  for (let offset = 0; offset < bytes.length; offset += zeroBlock.length) {
    const part = bytes.subarray(offset, offset + zeroBlock.length)
    if (!part.equals(zeroBlock.subarray(0, part.length))) return false
  }
  return true
}
function hashing(hash: ReturnType<typeof createHash>): Transform {
  return new Transform({ transform(chunk: Buffer, _encoding, callback) { hash.update(chunk); callback(null, chunk) } })
}

/** Encrypt and compress each regular snapshot file into unique objects; caller publishes the returned manifest. */
export async function uploadSnapshotArchive(directory: string, store: SnapshotObjectStore, key: Uint8Array, signal?: AbortSignal): Promise<SnapshotArchive> {
  checkKey(key)
  const files = await readdir(directory, { withFileTypes: true })
  if (!files.length || files.length > 64 || files.some(file => !file.isFile() || !validName(file.name))) throw new Error('Snapshot contains unsupported entries')
  const id = randomUUID()
  const prefix = `snapshots/${id}`
  const entries: SnapshotArchiveEntry[] = []
  try {
    for (const file of files.sort((a, b) => a.name.localeCompare(b.name))) {
      signal?.throwIfAborted()
      const objectKey = `${prefix}/${file.name}`
      const nonce = randomBytes(12)
      const cipher = createCipheriv('aes-256-gcm', key, nonce)
      cipher.setAAD(Buffer.from(`${id}/${file.name}`))
      const hash = createHash('sha256')
      const sourceHash = createHash('sha256')
      const output = new PassThrough()
      const handle = await open(join(directory, file.name), constants.O_RDONLY | constants.O_NOFOLLOW)
      const stat = await handle.stat()
      if (!stat.isFile() || !Number.isSafeInteger(stat.size)) { await handle.close(); throw new Error('Snapshot entry is not a regular file') }
      const source = handle.createReadStream()
      const piping = pipeline(source, hashing(sourceHash), createGzip(), cipher, hashing(hash), output, { signal })
      const uploading = Promise.resolve().then(() => store.putStream({ key: objectKey, body: output, signal }))
      try { await Promise.all([piping, uploading]) } catch (error) {
        output.destroy(); source.destroy()
        await Promise.allSettled([piping, uploading])
        // Completion may have succeeded even if its response was lost.
        await store.delete(objectKey, { signal: AbortSignal.timeout(1000) }).catch(() => undefined)
        throw error
      }
      entries.push({ name: file.name, key: objectKey, nonce: nonce.toString('hex'), tag: cipher.getAuthTag().toString('hex'), sha256: hash.digest('hex'), sourceSha256: sourceHash.digest('hex'), size: stat.size })
    }
    return { version: 1, id, entries }
  } catch (error) {
    await Promise.allSettled(entries.map(entry => store.delete(entry.key, { signal: AbortSignal.timeout(1000) })))
    throw error
  }
}

/** Validate untrusted persisted metadata before filesystem or storage operations. */
export function validateSnapshotArchive(archive: SnapshotArchive): void {
  if (!archive || typeof archive !== 'object' || typeof archive.id !== 'string' || archive.version !== 1 || !/^[a-f0-9]{8}-[a-f0-9]{4}-4[a-f0-9]{3}-[89ab][a-f0-9]{3}-[a-f0-9]{12}$/.test(archive.id) || !Array.isArray(archive.entries) || !archive.entries.length || archive.entries.length > 64) throw new Error('Invalid snapshot archive')
  const names = new Set<string>()
  for (const entry of archive.entries) {
    if (!entry || typeof entry !== 'object' || typeof entry.name !== 'string' || typeof entry.key !== 'string' || typeof entry.nonce !== 'string' || typeof entry.tag !== 'string' || typeof entry.sha256 !== 'string' || typeof entry.sourceSha256 !== 'string' || !validName(entry.name) || names.has(entry.name) || entry.key !== `snapshots/${archive.id}/${entry.name}` || basename(entry.key) !== entry.name || !/^[a-f0-9]{24}$/.test(entry.nonce) || !/^[a-f0-9]{32}$/.test(entry.tag) || !/^[a-f0-9]{64}$/.test(entry.sha256) || !/^[a-f0-9]{64}$/.test(entry.sourceSha256) || !Number.isSafeInteger(entry.size) || entry.size < 0) throw new Error('Invalid snapshot archive entry')
    names.add(entry.name)
  }
}

/** Restore into a new private staging directory. No file is installed as a live snapshot. */
export async function downloadSnapshotArchive(directory: string, store: SnapshotObjectStore, key: Uint8Array, archive: SnapshotArchive, signal?: AbortSignal): Promise<void> {
  checkKey(key)
  validateSnapshotArchive(archive)
  await mkdir(directory, { mode: 0o700 })
  try {
    for (const entry of archive.entries) {
      signal?.throwIfAborted()
      const { stream } = await store.getStream(entry.key, { signal })
      const hash = createHash('sha256')
      const decipher = createDecipheriv('aes-256-gcm', key, Buffer.from(entry.nonce, 'hex'))
      decipher.setAAD(Buffer.from(`${archive.id}/${entry.name}`))
      decipher.setAuthTag(Buffer.from(entry.tag, 'hex'))
      let size = 0
      const sourceHash = createHash('sha256')
      const limit = new Transform({ transform(chunk: Buffer, _encoding, callback) {
        size += chunk.length
        if (size > entry.size) callback(new Error('Snapshot archive exceeds expected size'))
        else callback(null, chunk)
      } })
      const restored = await open(join(directory, entry.name), 'wx', 0o600)
      let offset = 0
      const sparse = new Writable({
        write(chunk: Buffer, _encoding, callback) {
          const start = offset
          offset += chunk.length
          if (allZero(chunk)) { callback(); return }
          void (async () => {
            let written = 0
            while (written < chunk.length) {
              const result = await restored.write(chunk, written, chunk.length - written, start + written)
              if (!result.bytesWritten) throw new Error('Could not write snapshot file')
              written += result.bytesWritten
            }
          })().then(() => callback(), error => callback(error as Error))
        },
      })
      try {
        await pipeline(Readable.fromWeb(stream as never), hashing(hash), decipher, createGunzip(), limit, hashing(sourceHash), sparse, { signal })
        if (sourceHash.digest('hex') !== entry.sourceSha256) throw new Error(`Snapshot source checksum mismatch: ${entry.name}`)
        if (size !== entry.size) throw new Error(`Snapshot archive size mismatch: ${entry.name}`)
        if (hash.digest('hex') !== entry.sha256) throw new Error(`Snapshot archive checksum mismatch: ${entry.name}`)
        await restored.truncate(offset)
        await restored.sync()
      } finally { await restored.close() }
    }
    const restoredDirectory = await open(directory, 'r')
    try { await restoredDirectory.sync() } finally { await restoredDirectory.close() }
  } catch (error) {
    await rm(directory, { recursive: true, force: true })
    throw error
  }
}
