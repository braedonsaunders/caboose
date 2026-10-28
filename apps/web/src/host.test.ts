import { describe, expect, it } from 'vitest'
import { displayLabel, gpuLabel, healthFacts, runtimeLabel, upgradeLabel } from './host.js'

describe('host', () => {
  it('names the runtime, display protocol and GPU', () => {
    expect(runtimeLabel('container')).toBe('Container')
    expect(runtimeLabel('microvm')).toMatch(/microVM/)
    expect(displayLabel('caboose-display')).toBe('Caboose Display')
    expect(displayLabel('xpra-ws')).toBe('Xpra')
    expect(gpuLabel(null)).toMatch(/microVM/)
    expect(gpuLabel('wsl')).toMatch(/dxg/)
    expect(upgradeLabel({ state: 'failed' })).toMatch(/could not/)
  })

  it('reads either runtime’s health and flags problems', () => {
    const vm = healthFacts({ host: 'caboose-host', kvm: false, desk: {
      resident: 1, queued: 0, capacity: 4, suspended: 0, lastStartedAt: null, lastSuspendedAt: null, reconnects: 5,
      lastReconnectAt: '2026-10-28T10:00:00.000Z', lastError: 'boom', snapshotCpuFallbacks: 0,
    } })
    expect(vm.find(fact => fact.label === 'KVM')).toMatchObject({ problem: true })
    expect(vm.find(fact => fact.label === 'Running machines')?.value).toBe('1 of 4')
    expect(vm.find(fact => fact.label === 'Guest reconnects')).toMatchObject({ problem: true })
    expect(vm.find(fact => fact.label === 'Desk error')?.value).toBe('boom')
    expect(healthFacts({ host: 'caboose-host', runtime: 'container', gpu: 'none', container: 'caboose-owner', running: true }))
      .toEqual([{ label: 'Container', value: 'caboose-owner' }, { label: 'Container state', value: 'Running' }])
  })
})
