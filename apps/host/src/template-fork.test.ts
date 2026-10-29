import { expect, it } from 'vitest'
import type { DeskLaunchPlan } from '@braedonsaunders/appkit-desk'
import { assertSavedTemplateConfig } from './template-fork.js'

it('rejects a parked child with changed boot or device identities', () => {
  const plan = { hypervisor: 'cloud-hypervisor', overlay: { path: '/child.raw' }, tap: { device: 'tap3', mac: '06:00:00:00:00:03' }, vsock: { cid: 123, socketPath: '/child.sock' } } as DeskLaunchPlan
  const saved = { payload: { kernel: '/kernel', initramfs: '/initrd' }, disks: [{ path: '/child.raw', readonly: false }, { path: '/system', readonly: true }], net: [{ tap: 'tap3', mac: '06:00:00:00:00:03' }], vsock: { cid: 123, socket: '/child.sock' } }
  const attachments = [{ path: '/system', sha256: 'a'.repeat(64), kind: 'block' as const }]
  expect(() => assertSavedTemplateConfig(saved, plan, '/kernel', '/initrd', attachments)).not.toThrow()
  expect(() => assertSavedTemplateConfig({ ...saved, payload: { ...saved.payload, kernel: '/other' } }, plan, '/kernel', '/initrd', attachments)).toThrow(/identity/)
  expect(() => assertSavedTemplateConfig({ ...saved, disks: [saved.disks[0], { path: '/system', readonly: false }] }, plan, '/kernel', '/initrd', attachments)).toThrow(/identity/)
  expect(() => assertSavedTemplateConfig({ ...saved, vsock: { ...saved.vsock, cid: 124 } }, plan, '/kernel', '/initrd', attachments)).toThrow(/identity/)
})
