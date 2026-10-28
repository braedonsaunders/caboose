import { mkdtemp, readFile, readdir, rm, stat, writeFile } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { afterEach, expect, it, vi } from 'vitest'
import { openSettings, settingsLimits, SettingsStore, updateSettings } from './settings.js'

const defaults = { name: 'Caboose', memoryMb: 2048, vcpus: 2, idleMs: 600_000 }
const roots: string[] = []
afterEach(async () => { for (const root of roots.splice(0)) await rm(root, { recursive: true, force: true }) })

it('validates partial settings without coercion or changing the original', () => {
  expect(updateSettings(defaults, { name: '  My computer  ', memoryMb: 4096 }, settingsLimits())).toEqual({ ...defaults, name: 'My computer', memoryMb: 4096 })
  for (const input of [{ name: '' }, { name: 'a\nb' }, { name: 'x'.repeat(81) }, { memoryMb: '4096' },
    { memoryMb: 511 }, { memoryMb: 65537 }, { vcpus: 0 }, { vcpus: 1.5 }, { vcpus: 33 },
    { idleMs: 0 }, { idleMs: 59999 }, { idleMs: 86400001 }, { token: 'new-token' }]) {
    expect(() => updateSettings(defaults, input, settingsLimits())).toThrow()
  }
  expect(defaults.name).toBe('Caboose')
})

it('retains successful settings across restarts with private atomic storage', async () => {
  const root = await mkdtemp(join(tmpdir(), 'caboose-settings-')); roots.push(root)
  const path = join(root, 'caboose.json')
  const first = await openSettings(path, defaults)
  expect(first.get()).toEqual(defaults)
  await first.update({ name: 'Persistent', vcpus: 4 })
  expect((await stat(path)).mode & 0o777).toBe(0o600)
  expect(await readdir(root)).toEqual(['caboose.json'])
  const second = await openSettings(path, { ...defaults, name: 'Changed environment', vcpus: 1 })
  expect(second.get()).toEqual({ ...defaults, name: 'Persistent', vcpus: 4 })
  await expect(second.update({ name: 'Invalid transaction', memoryMb: 0 })).rejects.toThrow()
  expect(JSON.parse(await readFile(path, 'utf8')).name).toBe('Persistent')
})

it('refuses malformed stored settings rather than silently resetting them', async () => {
  const root = await mkdtemp(join(tmpdir(), 'caboose-settings-')); roots.push(root)
  const path = join(root, 'caboose.json')
  for (const contents of ['{', 'null', '[]', '{"vcpus":0}']) {
    await writeFile(path, contents)
    await expect(openSettings(path, defaults)).rejects.toThrow()
    expect(await readFile(path, 'utf8')).toBe(contents)
  }
})

it('merges concurrent writes and recovers after a failed persistence operation', async () => {
  const save = vi.fn().mockRejectedValueOnce(new Error('read-only volume')).mockResolvedValue(undefined)
  const store = new SettingsStore(defaults, settingsLimits(), { load: async () => undefined, save })
  await expect(store.update({ name: 'Not saved' })).rejects.toThrow('read-only volume')
  expect(store.get()).toEqual(defaults)
  await Promise.all([store.update({ memoryMb: 4096 }), store.update({ vcpus: 4 }), store.update({ name: 'Saved' })])
  expect(store.get()).toEqual({ ...defaults, memoryMb: 4096, vcpus: 4, name: 'Saved' })
  expect(save).toHaveBeenLastCalledWith(store.get())
})
