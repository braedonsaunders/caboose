import { expect, it, vi } from 'vitest'
import { verifyTemplateGuestComponents } from './template-builder.js'
import type { DeskHandle } from '@braedonsaunders/appkit-desk'

it('rejects an old or incomplete guest bundle before template capture', async () => {
  const run = vi.fn().mockResolvedValueOnce({ exitCode: 0, truncated: false, stdout: 'old-version\n' })
  await expect(verifyTemplateGuestComponents({ exec: run } as unknown as Pick<DeskHandle, 'exec'>, 'current')).rejects.toThrow(/complete Caboose component bundle/)
  expect(run).toHaveBeenCalledTimes(1)
  run.mockReset().mockResolvedValueOnce({ exitCode: 0, truncated: false, stdout: 'current\n' }).mockResolvedValueOnce({ exitCode: 1, truncated: false })
  await expect(verifyTemplateGuestComponents({ exec: run } as unknown as Pick<DeskHandle, 'exec'>, 'current')).rejects.toThrow(/missing a required/)
})
