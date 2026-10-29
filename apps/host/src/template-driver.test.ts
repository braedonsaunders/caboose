import { mkdtemp, rm, writeFile, chmod } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { expect, it, vi } from 'vitest'

vi.mock('@braedonsaunders/appkit-desk', async importOriginal => ({
  ...await importOriginal<typeof import('@braedonsaunders/appkit-desk')>(),
  DESK_TEMPLATE_VERSION: 3,
  forkDeskTemplate: vi.fn(),
  hostCpuSignature: vi.fn(async () => 'cpu'),
}))

import { createController } from './driver.js'
import { config } from './config.js'

it('passes a unique planned identity and strict lifecycle for a new opted-in computer', async () => {
  const root = await mkdtemp(join(tmpdir(), 'template-controller-'))
  try {
    for (const name of ['base.raw', 'vmlinux', 'initrd', 'vmm']) await writeFile(join(root, name), name)
    await chmod(join(root, 'vmm'), 0o700)
    const start = vi.fn(async (_options: unknown) => { throw new Error('intercepted before boot') })
    const controller = createController(config({ CABOOSE_IMAGE_ROOT: root, CABOOSE_VMM_PATH: join(root, 'vmm'), CABOOSE_VM_TEMPLATE: 'on' }), {
      identity: { id: 'child', slot: 3 }, desks: { start } as any, backend: { hypervisor: 'cloud-hypervisor' } as any,
      deviceExists: () => true, network: async () => {},
    })
    await expect(controller.wake()).rejects.toThrow(/intercepted/)
    const options = start.mock.calls[0]?.[0] as any
    expect(options.overlayPath).toBe(join(root, 'overlays', 'child.template', 'disk.raw'))
    expect(options.vsockCid).toBe(0x80000003)
    expect(options.network.macAddress).toBe('06:00:00:00:00:03')
    expect(options.strictMemoryRestore).toBe(true)
    expect(options.memoryRestoreMode).toBe('copyonwrite')
    expect(typeof options.template.holdFence).toBe('function')
    expect(typeof options.template.initialize).toBe('function')
  } finally { await rm(root, { recursive: true, force: true }) }
})
