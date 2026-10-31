import { COMMAND_LIMITS } from '../commands.js'
import { commandReceiptName, readCommandReceipt, maxCommandReceiptBytes } from './command-receipts.js'
import { createCipheriv, createDecipheriv, createHash, randomBytes, randomUUID } from 'node:crypto'
import { constants } from 'node:fs'
import { open, readFile, readdir, rm } from 'node:fs/promises'
import { dirname, join } from 'node:path'
import { Readable } from 'node:stream'
import { downloadSnapshotArchive, uploadSnapshotArchive, validateSnapshotArchive, type SnapshotArchive, type SnapshotObjectStore } from '../snapshot-archive.js'
import { writePrivateJson } from '../settings.js'

export interface PortableMetadata {
  computerId: string
  runtime: 'linux-microvm'
  architecture: 'x64' | 'arm64'
  runtimeVersion: string
  imageFormat: 'monolithic' | 'split'
  createdAt: string
}
export interface PortableSource { directory: string; metadata: PortableMetadata }
/** Trusted controller boundary, not a client assertion. Hold coherent disk and state immutable until work settles. */
export interface CaptureAuthority { withCapture<T>(work: (source: PortableSource) => Promise<T>): Promise<T> }
export interface PortableCheckpointRef { version: 1; id: string; key: string; keyId: string }
export interface PortableManifest { version: 1; metadata: PortableMetadata; archive: SnapshotArchive }
export type Compatibility = Pick<PortableMetadata, 'runtime' | 'architecture' | 'runtimeVersion'>
const uuid = /^[a-f0-9]{8}-[a-f0-9]{4}-4[a-f0-9]{3}-[89ab][a-f0-9]{3}-[a-f0-9]{12}$/
const maxManifest = 1024 * 1024
const required = ['disk.raw', 'vmlinux', 'initrd', 'keyring-secret', 'computer.json']
const stateFiles = ['caboose.json', 'agent-profiles.json', 'mcp-library.json', 'agent-tool-receipts.json', 'agent-routines.json', 'push-devices.json', 'activities.json']

function metadata(value: PortableMetadata): void {
  if (!value || !/^(owner|c-[a-f0-9]{10})$/.test(value.computerId) || value.runtime !== 'linux-microvm' || !['x64', 'arm64'].includes(value.architecture) || typeof value.runtimeVersion !== 'string' || !value.runtimeVersion.length || value.runtimeVersion.length > 256 || !['monolithic', 'split'].includes(value.imageFormat) || typeof value.createdAt !== 'string' || !Number.isFinite(Date.parse(value.createdAt))) throw new Error('Invalid portable computer metadata')
}
function names(files: string[], format: PortableMetadata['imageFormat']): void {
  const expected = [...required, ...(format === 'split' ? ['system.erofs'] : [])]
  if (expected.some(name => !files.includes(name)) || files.some(name => ![...expected, ...stateFiles].includes(name) && !commandReceiptName.test(name)) || files.filter(name => commandReceiptName.test(name)).length > COMMAND_LIMITS.kept) throw new Error('Incomplete or unsupported portable computer files')
}
async function bounded(stream: ReadableStream): Promise<Buffer> {
  const chunks: Buffer[] = []; let size = 0
  for await (const chunk of Readable.fromWeb(stream as never)) {
    size += chunk.length
    if (size > maxManifest) throw new Error('Portable manifest too large')
    chunks.push(Buffer.from(chunk))
  }
  return Buffer.concat(chunks)
}

/** Opt-in encrypted archives. Object storage is never used as a live writable disk. */
export class PortableComputerStore {
  readonly keyId: string
  private readonly key: Buffer
  constructor(private readonly store: SnapshotObjectStore, key: Uint8Array) {
    if (key.byteLength !== 32) throw new Error('Portable key must be 32 bytes')
    this.key = Buffer.from(key)
    this.keyId = createHash('sha256').update(this.key).digest('hex')
  }
  private check(ref: PortableCheckpointRef): void {
    if (!ref || ref.version !== 1 || !uuid.test(ref.id) || ref.key !== `computers/${ref.id}/manifest` || ref.keyId !== this.keyId) throw new Error('Invalid portable checkpoint reference or wrong key')
  }
  /** journalPath is a private, unique per-operation file on durable local storage. */
  async capture(authority: CaptureAuthority, journalPath: string, signal?: AbortSignal): Promise<PortableCheckpointRef> {
    const id = randomUUID()
    const ref: PortableCheckpointRef = { version: 1, id, key: `computers/${id}/manifest`, keyId: this.keyId }
    const receipt = { version: 1, ref, phase: 'uploading', keys: [] as string[] }
    const journal = await open(journalPath, 'wx', 0o600)
    await journal.close()
    const save = async () => {
      await writePrivateJson(journalPath, receipt)
      const parent = await open(dirname(journalPath), 'r')
      try { await parent.sync() } finally { await parent.close() }
    }
    await save()
    // Every key is journaled before its PUT, including requests with lost responses.
    const tracked: SnapshotObjectStore = {
      ...this.store,
      getStream: (key, options) => this.store.getStream(key, options),
      delete: (key, options) => this.store.delete(key, options),
      putStream: async input => { receipt.keys.push(input.key); await save(); await this.store.putStream(input) },
    }
    const result = await authority.withCapture(async source => {
      metadata(source.metadata)
      names(await readdir(source.directory), source.metadata.imageFormat)
      // Validate bounded required metadata before transferring large disk data.
      await validateState(source.directory, source.metadata.computerId)
      const archive = await uploadSnapshotArchive(source.directory, tracked, this.key, signal)
      const manifest: PortableManifest = { version: 1, metadata: structuredClone(source.metadata), archive }
      const nonce = randomBytes(12), cipher = createCipheriv('aes-256-gcm', this.key, nonce)
      cipher.setAAD(Buffer.from(ref.key))
      const body = Buffer.concat([cipher.update(JSON.stringify(manifest)), cipher.final()])
      const sealed = Buffer.concat([nonce, cipher.getAuthTag(), body])
      receipt.phase = 'publishing'; receipt.keys.push(ref.key); await save()
      signal?.throwIfAborted()
      await this.store.putStream({ key: ref.key, body: Readable.from([sealed]), signal })
      // Read back authenticated commit marker. A lost response leaves a recoverable receipt.
      await this.inspect(ref, source.metadata, signal)
      receipt.phase = 'committed'; await save()
      return ref
    })
    return result
  }
  async inspect(ref: PortableCheckpointRef, target: Compatibility, signal?: AbortSignal): Promise<PortableManifest> {
    this.check(ref)
    const bytes = await bounded((await this.store.getStream(ref.key, { signal })).stream)
    if (bytes.length < 29) throw new Error('Truncated portable manifest')
    const decipher = createDecipheriv('aes-256-gcm', this.key, bytes.subarray(0, 12))
    decipher.setAAD(Buffer.from(ref.key)); decipher.setAuthTag(bytes.subarray(12, 28))
    const manifest = JSON.parse(Buffer.concat([decipher.update(bytes.subarray(28)), decipher.final()]).toString('utf8')) as PortableManifest
    if (manifest.version !== 1) throw new Error('Unsupported portable manifest version')
    metadata(manifest.metadata); validateSnapshotArchive(manifest.archive)
    names(manifest.archive.entries.map(entry => entry.name), manifest.metadata.imageFormat)
    if (manifest.archive.entries.some(entry => commandReceiptName.test(entry.name) && entry.size > maxCommandReceiptBytes)) throw new Error('Command receipt exceeds size limit')
    if (target.runtime !== manifest.metadata.runtime || target.architecture !== manifest.metadata.architecture || target.runtimeVersion !== manifest.metadata.runtimeVersion) throw new Error('Incompatible portable runtime or architecture')
    return manifest
  }
  /** Destination must not exist. No live disk, registry, ownership or boot state is changed. */
  async restore(ref: PortableCheckpointRef, target: Compatibility, destination: string, signal?: AbortSignal): Promise<PortableManifest> {
    const manifest = await this.inspect(ref, target, signal)
    await downloadSnapshotArchive(destination, this.store, this.key, manifest.archive, signal)
    try { await validateState(destination, manifest.metadata.computerId) }
    catch (error) { await rm(destination, { recursive: true, force: true }); throw error }
    return manifest
  }
  /** Only uploading receipts are automatically reclaimable; publishing may already be committed. */
  async discardInterrupted(journalPath: string): Promise<void> {
    const receipt = JSON.parse(await readFile(journalPath, 'utf8')) as { version: number; ref: PortableCheckpointRef; phase: string; keys: string[] }
    this.check(receipt.ref)
    if (receipt.version !== 1 || receipt.phase !== 'uploading' || !Array.isArray(receipt.keys) || receipt.keys.some(key => !/^snapshots\/[a-f0-9-]{36}\/[A-Za-z0-9][A-Za-z0-9._-]{0,127}$/.test(key))) throw new Error('Receipt may be committed; inspect checkpoint before operator reconciliation')
    for (const key of receipt.keys) await this.store.delete(key, { signal: AbortSignal.timeout(30_000) })
    await rm(journalPath)
  }
}

async function validateState(directory: string, computerId: string): Promise<void> {
  for (const name of await readdir(directory)) {
    const match = commandReceiptName.exec(name)
    if (match) await readCommandReceipt(join(directory, name), match[1]!)
  }
  for (const name of ['computer.json', 'keyring-secret']) {
    const file = await open(join(directory, name), constants.O_RDONLY | constants.O_NOFOLLOW)
    try {
      const stat = await file.stat()
      if (!stat.isFile() || stat.size < 1 || stat.size > maxManifest) throw new Error(`Invalid portable ${name}`)
      const data = await file.readFile('utf8')
      if (name === 'computer.json') {
        const value = JSON.parse(data)
        if (value?.version !== 1 || value.record?.id !== computerId || !Number.isSafeInteger(value.record?.slot) || value.record.slot < 0 || !value.settings || typeof value.settings !== 'object') throw new Error('Invalid portable computer state')
      } else if (!/^[a-f0-9]{64}\n?$/.test(data)) throw new Error('Invalid portable keyring secret')
    } finally { await file.close() }
  }
}
