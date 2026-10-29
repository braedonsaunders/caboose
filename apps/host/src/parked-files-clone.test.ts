import { mkdtemp, readFile, rm, symlink, writeFile } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { expect, it } from 'vitest'
import { stageParkedDisk } from './parked-files-clone.js'

it('rejects symlink and oversized source disks without modifying them', async () => {
  const root = await mkdtemp(join(tmpdir(), 'parked-disk-'))
  try {
    const disk = join(root, 'disk')
    await writeFile(disk, 'disk contents')
    await symlink(disk, join(root, 'link'))
    await expect(stageParkedDisk(join(root, 'link'), root, 1024)).rejects.toThrow('Unsupported')
    await expect(stageParkedDisk(disk, root, 2)).rejects.toThrow('Unsupported')
    expect(await readFile(disk, 'utf8')).toBe('disk contents')
  } finally { await rm(root, { recursive: true, force: true }) }
})

it('keeps the staged image independent when reflinks are supported', async context => {
  const root = await mkdtemp(join(tmpdir(), 'parked-disk-'))
  try {
    const disk = join(root, 'disk')
    await writeFile(disk, 'before')
    let staged
    try { staged = await stageParkedDisk(disk, root, 1024) }
    catch (error) {
      if (['ENOTSUP', 'EOPNOTSUPP', 'ENOSYS', 'EINVAL'].includes((error as NodeJS.ErrnoException).code ?? '')) { context.skip(); return }
      throw error
    }
    await writeFile(disk, 'after!')
    expect(await readFile(staged.image, 'utf8')).toBe('before')
  } finally { await rm(root, { recursive: true, force: true }) }
})
