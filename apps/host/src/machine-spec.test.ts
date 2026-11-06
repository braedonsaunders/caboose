import { mkdtemp, readFile, rm } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { describe, expect, it } from 'vitest'
import { MachineSpecError, MachineSpecStore, folderTag, parseMachineSpec } from './machine-spec.js'

describe('a microVM computer\'s machine settings', () => {
  it('takes folders of the host, read-write or read-only, and nothing else', () => {
    expect(parseMachineSpec({})).toEqual({})
    expect(parseMachineSpec({ folders: [{ source: '/srv/games/', target: '/mnt/games', readOnly: false }] }))
      .toEqual({ folders: [{ source: '/srv/games', target: '/mnt/games', readOnly: false }] })
    expect(() => parseMachineSpec({ devices: [] })).toThrow(MachineSpecError)
    expect(() => parseMachineSpec({ folders: [{ source: 'relative', target: '/mnt/x', readOnly: true }] })).toThrow('absolute path')
    expect(() => parseMachineSpec({ folders: [{ source: '/a', target: '/home/caboose', readOnly: true }] })).toThrow('cannot replace')
    expect(() => parseMachineSpec({ folders: [{ source: '/a', target: '/mnt/x', readOnly: true }, { source: '/b', target: '/mnt/x', readOnly: false }] })).toThrow('Two folders')
    expect(() => parseMachineSpec({ folders: [{ source: '/a', target: '/mnt/x' }] })).toThrow('readOnly')
    expect(() => parseMachineSpec({ folders: Array.from({ length: 17 }, (_, i) => ({ source: `/s${i}`, target: `/t${i}`, readOnly: true })) })).toThrow('at most 16')
  })

  it('names each folder\'s virtio-fs tag within the device\'s 36 bytes', () => {
    expect(folderTag(15)).toBe('caboose-folder-15')
    expect(Buffer.byteLength(folderTag(15))).toBeLessThanOrEqual(36)
  })

  it('keeps its settings in the computer\'s state', async () => {
    const dir = await mkdtemp(join(tmpdir(), 'caboose-machine-'))
    try {
      const file = join(dir, 'machine.json')
      const store = await MachineSpecStore.open(file)
      expect(store.get()).toEqual({})
      await store.set({ folders: [{ source: '/srv/games', target: '/mnt/games', readOnly: false }] })
      expect(JSON.parse(await readFile(file, 'utf8'))).toEqual({ folders: [{ source: '/srv/games', target: '/mnt/games', readOnly: false }] })
      expect((await MachineSpecStore.open(file)).get().folders?.[0]?.target).toBe('/mnt/games')
      await expect(store.set({ folders: 'all' })).rejects.toThrow(MachineSpecError)
    } finally { await rm(dir, { recursive: true, force: true }) }
  })
})
