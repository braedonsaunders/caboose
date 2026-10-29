import { mkdtemp, mkdir, rm, writeFile } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { expect, it } from 'vitest'
import { vmPaths } from './vm-paths.js'

it('keeps existing disks on their original layout across opt-in changes', async () => {
  const root = await mkdtemp(join(tmpdir(), 'vm-paths-'))
  try {
    const overlays = join(root, 'overlays')
    await mkdir(overlays)
    await writeFile(join(overlays, 'old.raw'), '')
    expect(vmPaths(root, 'old', true).template).toBe(false)
    await writeFile(join(overlays, 'prior.resources.json'), '{}')
    expect(vmPaths(root, 'prior', true).template).toBe(false)
    expect(vmPaths(root, 'new', true).template).toBe(true)
    await mkdir(join(overlays, 'new.template'))
    expect(vmPaths(root, 'new', false).template).toBe(true)
    await writeFile(join(overlays, 'new.raw'), '')
    expect(() => vmPaths(root, 'new', true)).toThrow(/conflicting/)
  } finally { await rm(root, { recursive: true, force: true }) }
})
