import { expect, it, vi } from 'vitest'
import { buildTemplateSource, supportedTemplateVmm, verifyTemplateGuestComponents } from './template-builder.js'
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
