import { mkdtemp, mkdir, readFile, rm, writeFile } from 'node:fs/promises'
import { join } from 'node:path'
import { tmpdir } from 'node:os'
import { expect, it } from 'vitest'
import { selectSystemImage, usesSystemImage, validateDepotRestoreOptions } from './system-image.js'

it('binds only a new disk and retains the selected image across configuration changes', async () => {
  const root = await mkdtemp(join(tmpdir(), 'caboose-system-'))
  try {
    const first = join(root, 'one'), second = join(root, 'two'), binding = join(root, 'binding'), disk = join(root, 'disk'), snapshot = join(root, 'snapshot')
    for (const dir of [first, second]) { await mkdir(dir); for (const name of ['base.raw', 'vmlinux', 'initrd', 'system.erofs']) await writeFile(join(dir, name), `${dir}/${name}`) }
    const image = await selectSystemImage(binding, disk, snapshot, first)
    await writeFile(disk, 'existing')
    expect((await selectSystemImage(binding, disk, snapshot, second))?.directory).toBe(first)
    expect(await usesSystemImage(binding, disk, snapshot)).toBe(true)
    await writeFile(join(first, 'system.erofs'), 'changed')
    await expect(selectSystemImage(binding, disk, snapshot, second)).rejects.toThrow('retained system image changed')
    expect(JSON.parse(await readFile(binding, 'utf8')).hashes).toEqual(image?.hashes)
    await rm(binding)
    expect(await selectSystemImage(binding, disk, snapshot, second)).toBeNull()
    await rm(disk); await mkdir(snapshot)
    expect(await selectSystemImage(binding, disk, snapshot, second)).toBeNull()
  } finally { await rm(root, { recursive: true, force: true }) }
})

it('rejects a depot with copy-on-write restore because virtio-fs requires shared memory', () => {
  expect(() => validateDepotRestoreOptions('/depot', 'on')).toThrow(/requires shared memory/)
  expect(() => validateDepotRestoreOptions('/depot', 'off')).not.toThrow()
  expect(() => validateDepotRestoreOptions('/depot', undefined)).not.toThrow()
  expect(() => validateDepotRestoreOptions(undefined, 'on')).not.toThrow()
})
