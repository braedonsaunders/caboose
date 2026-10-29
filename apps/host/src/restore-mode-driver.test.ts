import { expect, it, vi } from 'vitest'

const state = vi.hoisted(() => ({ modes: [] as string[], received: undefined as unknown }))
vi.mock('@braedonsaunders/appkit-desk', async importOriginal => ({
  ...await importOriginal<typeof import('@braedonsaunders/appkit-desk')>(),
  DESK_MEMORY_RESTORE_MODES: state.modes,
  createDeskHost: (options: unknown) => { state.received = options; return {} },
}))
import { createDeskPool } from './driver.js'
import { config } from './config.js'

it('requires AppKit ondemand capability and forwards the selected mode', () => {
  const settings = config({ CABOOSE_VM_RESTORE_MODE: 'ondemand' })
  const backend = { hypervisor: 'cloud-hypervisor' as const, async boot() { throw new Error('unused') } }
  expect(() => createDeskPool(settings, { backend })).toThrow(/compatible AppKit/)
  state.modes.push('ondemand')
  createDeskPool(settings, { backend })
  expect(state.received).toMatchObject({ memoryRestoreMode: 'ondemand', parkWithMemory: true })
})
