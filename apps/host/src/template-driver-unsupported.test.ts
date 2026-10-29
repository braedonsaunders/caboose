import { mkdtemp, rm } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { expect, it, vi } from 'vitest'

vi.mock('@braedonsaunders/appkit-desk', async importOriginal => ({
  ...await importOriginal<typeof import('@braedonsaunders/appkit-desk')>(),
  DESK_TEMPLATE_VERSION: undefined,
  forkDeskTemplate: undefined,
}))
import { createController } from './driver.js'
import { config } from './config.js'

it('refuses a template wake when AppKit lacks template support', async () => {
  const root = await mkdtemp(join(tmpdir(), 'template-driver-'))
  try {
    const start = vi.fn(async (_options: unknown) => { throw new Error('must not cold boot') })
    const controller = createController(config({ CABOOSE_IMAGE_ROOT: root, CABOOSE_VM_TEMPLATE: 'on' }), {
      desks: { start } as any, backend: { hypervisor: 'cloud-hypervisor' } as any,
      deviceExists: () => true, network: async () => {},
    })
    await expect(controller.wake()).rejects.toThrow(/compatible AppKit/)
    expect(start).not.toHaveBeenCalled()
  } finally { await rm(root, { recursive: true, force: true }) }
})
