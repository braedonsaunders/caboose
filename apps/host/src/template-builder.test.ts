import { mkdtemp, open, rm, truncate } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { expect, it, vi } from 'vitest'
import { buildTemplateSource, measureSnapshotSparsity, supportedTemplateVmm, verifyTemplateGuestComponents } from './template-builder.js'
import type { DeskHandle } from '@braedonsaunders/appkit-desk'

it('rejects an old or incomplete guest bundle before template capture', async () => {
  const run = vi.fn().mockResolvedValueOnce({ exitCode: 0, truncated: false, stdout: 'old-version\n' })
  await expect(verifyTemplateGuestComponents({ exec: run } as unknown as Pick<DeskHandle, 'exec'>, 'current')).rejects.toThrow(/complete Caboose component bundle/)
  expect(run).toHaveBeenCalledTimes(1)
  run.mockReset().mockResolvedValueOnce({ exitCode: 0, truncated: false, stdout: 'current\n' }).mockResolvedValueOnce({ exitCode: 1, truncated: false })
  await expect(verifyTemplateGuestComponents({ exec: run } as unknown as Pick<DeskHandle, 'exec'>, 'current')).rejects.toThrow(/missing a required/)
})

it('coalesces concurrent construction of the same source and releases a failed build', async () => {
  const options = { directory: 'relative', baseImage: '/base', kernel: '/kernel', initramfs: '/initrd', vmmPath: '/vmm', memoryMb: 512, vcpus: 1 }
  const first = buildTemplateSource(options)
  const second = buildTemplateSource(options)
  expect(second).toBe(first)
  await expect(first).rejects.toThrow(/absolute paths/)
  const retry = buildTemplateSource(options)
  expect(retry).not.toBe(first)
  await expect(retry).rejects.toThrow(/absolute paths/)
})

it('accepts only the validated v54 VMM builds', () => {
  expect(supportedTemplateVmm('cloud-hypervisor v54.0')).toBe(true)
  expect(supportedTemplateVmm('cloud-hypervisor v54.0.0-appkit-incremental.1')).toBe(true)
  expect(supportedTemplateVmm('cloud-hypervisor v54.0.0-appkit-incremental.2')).toBe(false)
})

it('measures sparse hole savings on a snapshot memory-ranges file', async () => {
  const dir = await mkdtemp(join(tmpdir(), 'template-sparse-'))
  try {
    const file = join(dir, 'memory-ranges')
    const handle = await open(file, 'w')
    await handle.close()
    await truncate(file, 64 * 1024 * 1024)
    const sparsity = await measureSnapshotSparsity(dir)
    expect(sparsity.logicalBytes).toBe(64 * 1024 * 1024)
    expect(sparsity.allocatedBytes).toBeLessThan(sparsity.logicalBytes)
    expect(sparsity.savedBytes).toBe(sparsity.logicalBytes - sparsity.allocatedBytes)
  } finally {
    await rm(dir, { recursive: true, force: true })
  }
})
