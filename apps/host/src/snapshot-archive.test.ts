import { mkdtemp, mkdir, readFile, readdir, rm, stat, writeFile } from 'node:fs/promises'
import { randomBytes } from 'node:crypto'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { describe, expect, it } from 'vitest'
import { downloadSnapshotArchive, uploadSnapshotArchive, type SnapshotObjectStore } from './snapshot-archive.js'

function storage() {
  const objects = new Map<string, Buffer>()
  const store: SnapshotObjectStore = {
    async putStream({ key, body }) { const chunks: Buffer[] = []; for await (const chunk of body) chunks.push(Buffer.from(chunk)); objects.set(key, Buffer.concat(chunks)) },
    async getStream(key) { const bytes = objects.get(key); if (!bytes) throw new Error('missing'); return { stream: new ReadableStream({ start(controller) { controller.enqueue(bytes); controller.close() } }) } },
    async delete(key) { objects.delete(key) },
  }
  return { store, objects }
}
describe('snapshot archives', () => {
  it('compresses and encrypts files and restores them into staging', async () => {
    const root = await mkdtemp(join(tmpdir(), 'snapshot-archive-'))
    const source = join(root, 'source'), target = join(root, 'target')
    try {
      await mkdir(source); await writeFile(join(source, 'memory-ranges'), 'private contents'.repeat(1000)); await writeFile(join(source, 'state.json'), '{}')
      const key = randomBytes(32), { store, objects } = storage()
      const manifest = await uploadSnapshotArchive(source, store, key)
      expect([...objects.values()].some(value => value.includes(Buffer.from('private contents')))).toBe(false)
      await downloadSnapshotArchive(target, store, key, manifest)
      expect(await readFile(join(target, 'memory-ranges'), 'utf8')).toBe('private contents'.repeat(1000))
      expect(await readdir(target)).toEqual(['memory-ranges', 'state.json'])
    } finally { await rm(root, { recursive: true, force: true }) }
  })
  it('refuses corrupt objects and removes the incomplete staging directory', async () => {
    const root = await mkdtemp(join(tmpdir(), 'snapshot-archive-'))
    const source = join(root, 'source'), target = join(root, 'target')
    try {
      await mkdir(source); await writeFile(join(source, 'memory-ranges'), 'data')
      const key = randomBytes(32), { store, objects } = storage()
      const manifest = await uploadSnapshotArchive(source, store, key)
      objects.set(manifest.entries[0]!.key, Buffer.from('tampered'))
      await expect(downloadSnapshotArchive(target, store, key, manifest)).rejects.toThrow()
      await expect(readdir(target)).rejects.toMatchObject({ code: 'ENOENT' })
    } finally { await rm(root, { recursive: true, force: true }) }
  })
  it('cleans uploaded objects when a later upload fails', async () => {
    const root = await mkdtemp(join(tmpdir(), 'snapshot-archive-'))
    try {
      await writeFile(join(root, 'a'), 'a'); await writeFile(join(root, 'b'), 'b')
      const { store, objects } = storage()
      const put = store.putStream
      let calls = 0
      store.putStream = async input => { if (++calls === 2) throw new Error('offline'); await put(input) }
      await expect(uploadSnapshotArchive(root, store, randomBytes(32))).rejects.toThrow('offline')
      expect(objects.size).toBe(0)
    } finally { await rm(root, { recursive: true, force: true }) }
  })
  it('rejects unsafe paths before creating a staging directory', async () => {
    const root = await mkdtemp(join(tmpdir(), 'snapshot-archive-'))
    const target = join(root, 'target')
    try {
      const { store } = storage()
      await expect(downloadSnapshotArchive(target, store, randomBytes(32), { version: 1, id: '00000000-0000-4000-8000-000000000000', entries: [{ name: '../escape', key: 'bad', nonce: '', tag: '', sha256: '', sourceSha256: '', size: 0 }] })).rejects.toThrow('Invalid')
      await expect(readdir(target)).rejects.toMatchObject({ code: 'ENOENT' })
    } finally { await rm(root, { recursive: true, force: true }) }
  })

  it('rejects duplicate entries before touching the restore path', async () => {
    const root = await mkdtemp(join(tmpdir(), 'snapshot-archive-')), source = join(root, 'source'), target = join(root, 'target')
    try {
      await mkdir(source); await writeFile(join(source, 'state.json'), '{}')
      const key = randomBytes(32), { store } = storage()
      const manifest = await uploadSnapshotArchive(source, store, key)
      manifest.entries.push({ ...manifest.entries[0]! })
      await expect(downloadSnapshotArchive(target, store, key, manifest)).rejects.toThrow('Invalid')
      await expect(readdir(target)).rejects.toMatchObject({ code: 'ENOENT' })
    } finally { await rm(root, { recursive: true, force: true }) }
  })

  it('restores zero-filled memory as a sparse file', async () => {
    const root = await mkdtemp(join(tmpdir(), 'snapshot-archive-')), source = join(root, 'source'), target = join(root, 'target')
    try {
      await mkdir(source); await writeFile(join(source, 'memory-ranges'), Buffer.alloc(4 * 1024 * 1024))
      const key = randomBytes(32), { store } = storage()
      const manifest = await uploadSnapshotArchive(source, store, key)
      await downloadSnapshotArchive(target, store, key, manifest)
      const info = await stat(join(target, 'memory-ranges'))
      expect(info.size).toBe(4 * 1024 * 1024)
      expect(info.blocks * 512).toBeLessThan(info.size)
    } finally { await rm(root, { recursive: true, force: true }) }
  })

})
