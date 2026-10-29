import { mkdtemp, mkdir, readFile, rm, writeFile } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { expect, it } from 'vitest'
import { ParkedFilesStore } from './parked-files-store.js'

it('binds a view to the exact snapshot marker and fails closed if it disappears', async () => {
  const root = await mkdtemp(join(tmpdir(), 'parked-store-'))
  try {
    const snapshot = join(root, 'snapshot'), staging = join(root, 'stages'), directory = join(staging, '.parked-files-abc123')
    await mkdir(snapshot); await mkdir(directory, { recursive: true, mode: 0o700 }); await writeFile(join(directory, 'disk.raw'), 'disk')
    const store = new ParkedFilesStore(snapshot, staging)
    const intent = { version: 2 as const, id: '12345678-1234-4123-8123-123456789abc', branches: [], homeDevice: 64769 }
    await store.publish({ directory, image: join(directory, 'disk.raw') }, intent, snapshot, () => true)
    expect(await store.read()).toEqual({ id: intent.id, homeDevice: 64769, directory, image: join(directory, 'disk.raw') })
    await writeFile(join(snapshot, 'files-generation'), 'different\n')
    expect(await store.read()).toBeUndefined()
    await rm(snapshot, { recursive: true })
    expect(await store.read()).toBeUndefined()
  } finally { await rm(root, { recursive: true, force: true }) }
})

it('removes a pointer when wake cancels publication during rename', async () => {
  const root = await mkdtemp(join(tmpdir(), 'parked-store-'))
  try {
    const snapshot = join(root, 'snapshot'), staging = join(root, 'stages'), directory = join(staging, '.parked-files-abc123')
    await mkdir(snapshot); await mkdir(directory, { recursive: true, mode: 0o700 }); await writeFile(join(directory, 'disk.raw'), 'disk')
    const store = new ParkedFilesStore(snapshot, staging)
    let checks = 0
    const intent = { version: 2 as const, id: '12345678-1234-4123-8123-123456789abc', branches: [], homeDevice: 64769 }
    await expect(store.publish({ directory, image: join(directory, 'disk.raw') }, intent, snapshot, () => ++checks === 1)).rejects.toThrow('cancelled')
    expect(await store.read()).toBeUndefined()
    await expect(readFile(join(snapshot, 'files-generation'))).rejects.toMatchObject({ code: 'ENOENT' })
  } finally { await rm(root, { recursive: true, force: true }) }
})
