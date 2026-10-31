/** Real S3 acceptance. Only use a dedicated disposable bucket. */
import assert from 'node:assert/strict'
import { randomBytes } from 'node:crypto'
import { mkdtemp, mkdir, writeFile, readFile, rm } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { createStorage } from '@braedonsaunders/appkit-storage'
import { PortableComputerStore, type PortableSource } from '../src/portable-storage/index.js'

if (process.env.CABOOSE_PORTABLE_ACCEPTANCE !== 'disposable-bucket') throw new Error('Set CABOOSE_PORTABLE_ACCEPTANCE=disposable-bucket for an isolated test bucket only')
const { S3_ENDPOINT, S3_BUCKET, S3_ACCESS_KEY_ID, S3_SECRET_ACCESS_KEY } = process.env
if (!S3_ENDPOINT || !S3_BUCKET || !S3_ACCESS_KEY_ID || !S3_SECRET_ACCESS_KEY) throw new Error('Set S3_ENDPOINT, S3_BUCKET, S3_ACCESS_KEY_ID, S3_SECRET_ACCESS_KEY')
const objects = createStorage({ endpoint: S3_ENDPOINT, bucket: S3_BUCKET, accessKeyId: S3_ACCESS_KEY_ID, secretAccessKey: S3_SECRET_ACCESS_KEY, region: 'us-east-1' })
const root = await mkdtemp(join(tmpdir(), 'portable-s3-'))
const keys = new Set<string>()
const tracked = {
  putStream: async (input: Parameters<typeof objects.putStream>[0]) => { keys.add(input.key); await objects.putStream(input) },
  getStream: objects.getStream.bind(objects), delete: objects.delete.bind(objects),
}
try {
  const directory = join(root, 'source'); await mkdir(directory)
  const disk = randomBytes(12 * 1024 * 1024) // exercises multipart, incompressible data
  for (const [name, value] of Object.entries({ 'disk.raw': disk, vmlinux: Buffer.from('kernel fixture'), initrd: Buffer.from('initrd fixture'), 'keyring-secret': randomBytes(32).toString('hex'), 'computer.json': JSON.stringify({ version: 1, record: { id: 'owner', slot: 0 }, settings: { name: 'Acceptance' } }) })) await writeFile(join(directory, name), value)
  const source: PortableSource = { directory, metadata: { computerId: 'owner', runtime: 'linux-microvm', architecture: 'x64', runtimeVersion: 'acceptance-fixture', imageFormat: 'monolithic', createdAt: new Date().toISOString() } }
  const key = randomBytes(32), writer = new PortableComputerStore(tracked, key)
  const ref = await writer.capture({ withCapture: async work => work(source) }, join(root, 'receipt'))
  await rm(directory, { recursive: true }) // restore cannot accidentally depend on source files
  const reader = new PortableComputerStore(objects, key)
  await reader.restore(ref, source.metadata, join(root, 'restored'))
  assert.deepEqual(await readFile(join(root, 'restored', 'disk.raw')), disk)
  await assert.rejects(reader.restore(ref, { ...source.metadata, architecture: 'arm64' }, join(root, 'incompatible')))
  // Real object corruption must not install a destination.
  const manifest = await reader.inspect(ref, source.metadata)
  await objects.putStream({ key: manifest.archive.entries.find(entry => entry.name === 'disk.raw')!.key, body: (async function* () { yield Buffer.from('corrupt') })() })
  await assert.rejects(reader.restore(ref, source.metadata, join(root, 'damaged')))
  await assert.rejects(readFile(join(root, 'damaged', 'disk.raw')))
  console.log('PASS: encrypted multipart archive, independent restore, compatibility rejection, corruption cleanup')
} finally {
  const results = await Promise.allSettled([...keys].map(key => objects.delete(key)))
  objects.client.destroy()
  await rm(root, { recursive: true, force: true })
  if (results.some(result => result.status === 'rejected')) throw new Error('Acceptance object cleanup failed; remove disposable bucket')
}
