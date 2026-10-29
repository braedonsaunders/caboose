import { expect, it } from 'vitest'
import { config } from './config.js'

it('validates opt-in Cloud Hypervisor memory options', () => {
  expect(config({}).vmCow).toBe(false)
  expect(config({ CABOOSE_VM_COW: 'on', CABOOSE_VM_FREE_PAGE_REPORTING: 'on' })).toMatchObject({ vmCow: true, vmFreePageReporting: true })
  expect(() => config({ CABOOSE_VM_COW: 'yes' })).toThrow('CABOOSE_VM_COW')
})

it('refuses Cloud Hypervisor flags on unsupported runtimes', async () => {
  expect(() => config({ CABOOSE_RUNTIME: 'container', CABOOSE_VM_COW: 'on' })).toThrow('microVM')
  expect(() => config({ CABOOSE_VM_DEPOT: '/var/lib/caboose/depot', CABOOSE_VM_COW: 'on' })).toThrow('cannot be combined')
  const { createDeskPool } = await import('./driver.js')
  const backend = { hypervisor: 'virtualization' as const, async boot() { throw new Error('unused') } }
  expect(() => createDeskPool(config({ CABOOSE_VM_FREE_PAGE_REPORTING: 'on' }), { backend })).toThrow('unavailable on macOS')
})
