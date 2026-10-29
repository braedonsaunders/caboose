import { createHash } from 'node:crypto'
import { existsSync } from 'node:fs'
import { lstat, mkdir, mkdtemp, readFile, rm, writeFile } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { afterEach, beforeEach, describe, expect, it } from 'vitest'
import { assertRestorable, discardRestoredDisk, installRestoredDisk, recoverRestoredDisk, RestoreRecoveryError, type RestorePaths } from './restore-journal.js'
import type { SystemImageBinding } from './system-image.js'

const hash = (value: string) => createHash('sha256').update(value).digest('hex')

describe('restored disk installation', () => {
  let root: string
  let paths: RestorePaths
  let staged: string
  let binding: SystemImageBinding

  beforeEach(async () => {
    root = await mkdtemp(join(tmpdir(), 'caboose-restore-'))
    await mkdir(join(root, 'overlays', 'c1.backup', 'restores'), { recursive: true })
    await mkdir(join(root, 'image'))
    for (const file of ['vmlinux', 'initrd', 'system.erofs']) await writeFile(join(root, 'image', file), file)
    binding = { version: 1, directory: join(root, 'image'), hashes: { 'base.raw': hash('base'), vmlinux: hash('vmlinux'), initrd: hash('initrd'), 'system.erofs': hash('system.erofs') } }
    paths = { disk: join(root, 'overlays', 'c1.raw'), binding: join(root, 'overlays', 'c1.system-image.json'), journal: join(root, 'overlays', 'c1.restore.json') }
    staged = join(root, 'overlays', 'c1.backup', 'restores', 'disk.raw')
    await writeFile(paths.disk, 'old disk')
    await writeFile(staged, 'restored disk')
  })
  afterEach(async () => { await rm(root, { recursive: true, force: true }) })

  async function journalFor(binding: SystemImageBinding | null) {
    const info = await lstat(staged)
    await writeFile(paths.journal, JSON.stringify({ version: 1, staged: { path: staged, dev: info.dev, ino: info.ino }, binding }))
  }

  it('replaces the disk and binding, and leaves no journal', async () => {
    await installRestoredDisk(paths, { image: staged, binding })
    expect(await readFile(paths.disk, 'utf8')).toBe('restored disk')
    expect(JSON.parse(await readFile(paths.binding, 'utf8'))).toEqual(binding)
    expect(existsSync(staged)).toBe(false)
    expect(existsSync(paths.journal)).toBe(false)
  })

  it('a disk restored without a split image drops a binding it had', async () => {
    await writeFile(paths.binding, JSON.stringify(binding))
    await installRestoredDisk(paths, { image: staged, binding: null })
    expect(existsSync(paths.binding)).toBe(false)
  })

  it('finishes an installation interrupted before the disk moved', async () => {
    await journalFor(binding)
    await recoverRestoredDisk(paths)
    expect(await readFile(paths.disk, 'utf8')).toBe('restored disk')
    expect(JSON.parse(await readFile(paths.binding, 'utf8'))).toEqual(binding)
    expect(existsSync(paths.journal)).toBe(false)
  })

  it('finishes an installation interrupted after the disk moved, before the binding was written', async () => {
    await journalFor(binding)
    const { rename } = await import('node:fs/promises')
    await rename(staged, paths.disk)
    await recoverRestoredDisk(paths)
    expect(await readFile(paths.disk, 'utf8')).toBe('restored disk')
    expect(JSON.parse(await readFile(paths.binding, 'utf8'))).toEqual(binding)
  })

  it('refuses to guess when the journaled disk is nowhere', async () => {
    await journalFor(binding)
    await rm(staged)
    await expect(recoverRestoredDisk(paths)).rejects.toThrow(RestoreRecoveryError)
    expect(await readFile(paths.disk, 'utf8')).toBe('old disk')
    await writeFile(paths.journal, 'torn')
    await expect(recoverRestoredDisk(paths)).rejects.toThrow(/unreadable restore journal/)
    await discardRestoredDisk(paths)
    await recoverRestoredDisk(paths)
  })

  it('refuses an image this host lacks, and an uninitialized template computer, before changing anything', async () => {
    await expect(assertRestorable(paths, { image: staged, binding: { ...binding, hashes: { ...binding.hashes, initrd: hash('other') } } })).rejects.toThrow(/initrd is not on this host/)
    await expect(installRestoredDisk({ ...paths, template: { initialized: false } }, { image: staged, binding })).rejects.toThrow(/Start this computer once/)
    expect(await readFile(paths.disk, 'utf8')).toBe('old disk')
    expect(existsSync(paths.journal)).toBe(false)
    await installRestoredDisk({ ...paths, template: { initialized: true } }, { image: staged, binding })
    expect(await readFile(paths.disk, 'utf8')).toBe('restored disk')
  })
})
