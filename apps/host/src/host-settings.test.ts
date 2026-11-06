import { existsSync } from 'node:fs'
import { mkdir, mkdtemp, readFile, rm, stat, writeFile } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { afterEach, describe, expect, it } from 'vitest'
import { ComputerRegistry, LEGACY_COMPUTER } from './computers.js'
import { HostSettings, phoneHostName, settleLegacyComputer } from './host-settings.js'

describe('phoneHostName', () => {
  it("names a host by its own name, else its computer's, else the machine's", () => {
    expect(phoneHostName('Den', 'Kids', 'lucid-gpu')).toBe('Den')
    expect(phoneHostName(null, 'Kids', 'lucid-gpu')).toBe('Kids')
    expect(phoneHostName(null, '  ', 'lucid-gpu')).toBe('lucid-gpu')
    expect(phoneHostName(null, undefined, 'lucid-gpu')).toBe('lucid-gpu')
    expect(phoneHostName(null, null, '')).toBe('Caboose')
  })
})

const roots: string[] = []
afterEach(async () => { for (const root of roots.splice(0)) await rm(root, { recursive: true, force: true }) })
async function root(): Promise<string> {
  const path = await mkdtemp(join(tmpdir(), 'caboose-host-settings-'))
  roots.push(path)
  return path
}

describe('settleLegacyComputer', () => {
  it("moves the built-in computer's files into its own directory and hands its name and role to the host", async () => {
    const dir = await root()
    await writeFile(join(dir, 'caboose.json'), JSON.stringify({ name: 'Den', memoryMb: 8192 }))
    await writeFile(join(dir, 'push-devices.json'), '[]')
    await writeFile(join(dir, 'keyring-secret'), 'a'.repeat(64))
    await mkdir(join(dir, 'commands'), { mode: 0o700 })
    await writeFile(join(dir, 'commands', 'one.json'), '{"id":"one"}')
    // Host files stay where they are.
    await writeFile(join(dir, 'phones.json'), '[]')
    await mkdir(join(dir, 'overlays'))
    await writeFile(join(dir, 'overlays', 'owner.raw'), 'disk')
    const computers = await ComputerRegistry.open(dir)
    await settleLegacyComputer(dir, computers)

    const own = join(dir, 'computers', LEGACY_COMPUTER)
    expect(JSON.parse(await readFile(join(own, 'caboose.json'), 'utf8'))).toEqual({ name: 'Den', memoryMb: 8192 })
    expect(await readFile(join(own, 'keyring-secret'), 'utf8')).toBe('a'.repeat(64))
    expect(await readFile(join(own, 'commands', 'one.json'), 'utf8')).toBe('{"id":"one"}')
    expect((await stat(join(own, 'commands'))).mode & 0o777).toBe(0o700)
    expect(existsSync(join(own, 'push-devices.json'))).toBe(true)
    for (const name of ['caboose.json', 'push-devices.json', 'keyring-secret', 'commands']) expect(existsSync(join(dir, name)), name).toBe(false)
    expect(existsSync(join(dir, 'phones.json'))).toBe(true)
    expect(await readFile(join(dir, 'overlays', 'owner.raw'), 'utf8')).toBe('disk')
    expect((await HostSettings.open(join(dir, 'host.json'))).get()).toEqual({ name: 'Den', defaultComputer: LEGACY_COMPUTER })
  })

  it('finishes a move a crash interrupted, never overwriting what already moved', async () => {
    const dir = await root()
    const own = join(dir, 'computers', LEGACY_COMPUTER)
    await mkdir(own, { recursive: true })
    await writeFile(join(own, 'caboose.json'), JSON.stringify({ name: 'Moved' }))
    await writeFile(join(dir, 'caboose.json'), JSON.stringify({ name: 'Left behind' }))
    await writeFile(join(dir, 'agent-profiles.json'), '{"profiles":[]}')
    await writeFile(join(dir, 'computers.json'), JSON.stringify({ computers: [] }))
    const computers = await ComputerRegistry.open(dir)
    await settleLegacyComputer(dir, computers)
    expect(JSON.parse(await readFile(join(own, 'caboose.json'), 'utf8'))).toEqual({ name: 'Moved' })
    // The copy left at the root is kept, not deleted.
    expect(existsSync(join(dir, 'caboose.json'))).toBe(true)
    expect(await readFile(join(own, 'agent-profiles.json'), 'utf8')).toBe('{"profiles":[]}')
    // Running it again changes nothing.
    await settleLegacyComputer(dir, computers)
    expect(JSON.parse(await readFile(join(own, 'caboose.json'), 'utf8'))).toEqual({ name: 'Moved' })
  })

  it('keeps the name Caboose for a built-in computer its owner never renamed, and gives the host none', async () => {
    const dir = await root()
    await writeFile(join(dir, 'computers.json'), JSON.stringify({ computers: [] }))
    const computers = await ComputerRegistry.open(dir)
    await settleLegacyComputer(dir, computers)
    expect(JSON.parse(await readFile(join(dir, 'computers', LEGACY_COMPUTER, 'caboose.json'), 'utf8'))).toEqual({ name: 'Caboose' })
    expect((await HostSettings.open(join(dir, 'host.json'))).get()).toEqual({ name: null, defaultComputer: LEGACY_COMPUTER })
  })

  it('leaves a new host alone', async () => {
    const dir = await root()
    const computers = await ComputerRegistry.open(dir)
    await settleLegacyComputer(dir, computers)
    expect(existsSync(join(dir, 'host.json'))).toBe(false)
    expect(existsSync(join(dir, 'computers'))).toBe(false)
    expect((await HostSettings.open(join(dir, 'host.json'))).get()).toEqual({ name: null, defaultComputer: null })
  })
})

describe('HostSettings', () => {
  it('keeps a name and a default computer, and checks both', async () => {
    const dir = await root()
    const path = join(dir, 'host.json')
    const settings = await HostSettings.open(path)
    await expect(settings.update({ name: '' })).rejects.toThrow(/name/)
    await expect(settings.update({ defaultComputer: 'nope' })).rejects.toThrow(/computer id/)
    await expect(settings.update({ defaultComputer: 'c-0123456789' }, () => false)).rejects.toThrow(/not found/)
    await expect(settings.update({ color: 'red' })).rejects.toThrow(/Unknown/)
    expect(await settings.update({ name: ' Den ', defaultComputer: 'c-0123456789' })).toEqual({ name: 'Den', defaultComputer: 'c-0123456789' })
    expect((await HostSettings.open(path)).get()).toEqual({ name: 'Den', defaultComputer: 'c-0123456789' })
  })

  it('adopts a first computer and moves on from a deleted default', async () => {
    const settings = HostSettings.memory()
    await settings.adopt('c-0123456789')
    await settings.adopt('c-abcdefabcd')
    expect(settings.get().defaultComputer).toBe('c-0123456789')
    await settings.forget('c-abcdefabcd', null)
    expect(settings.get().defaultComputer).toBe('c-0123456789')
    await settings.forget('c-0123456789', 'c-abcdefabcd')
    expect(settings.get().defaultComputer).toBe('c-abcdefabcd')
    await settings.forget('c-abcdefabcd', null)
    expect(settings.get().defaultComputer).toBeNull()
  })
})
