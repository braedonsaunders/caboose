import { describe, expect, it } from 'vitest'
import { fleetTotals, gpuLabel, healthFacts, healthProblems, runtimeLabel, sharePercent, upgradeLabel } from './host.js'

describe('host', () => {
  it('names the runtime and GPU', () => {
    expect(runtimeLabel('container')).toBe('Container')
    expect(runtimeLabel('microvm')).toBe('microVM')
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

  it('lifts host problems out of health, and shares a machine in whole percent', () => {
    const desk = { resident: 0, queued: 0, capacity: 1, suspended: 0, lastStartedAt: null, lastSuspendedAt: null, reconnects: 0, lastReconnectAt: null, lastError: null, snapshotCpuFallbacks: 0 }
    expect(healthProblems({ host: 'caboose-host', kvm: true, desk })).toEqual([])
    const mac = { host: 'caboose-host', hypervisor: 'virtualization' as const, kvm: false, desk }
    expect(healthProblems(mac)).toEqual([])
    expect(healthFacts(mac)).toContainEqual({ label: 'Hypervisor', value: 'Apple Virtualization.framework' })
    expect(healthFacts(mac).some(fact => fact.label === 'KVM')).toBe(false)
    expect(healthProblems({ host: 'caboose-host', kvm: false, desk: { ...desk, lastError: 'boot failed' } })).toEqual([
      '/dev/kvm is not present, so the host cannot start a microVM.', 'boot failed',
    ])
    // A parked container is not running, and that is not a problem.
    expect(healthProblems({ host: 'caboose-host', runtime: 'container', gpu: 'none', container: 'caboose-owner', running: false })).toEqual([])
    expect(sharePercent(6144, 32768)).toBe(19)
    expect(fleetTotals([
      { state: 'running', settings: { memoryMb: 4096, vcpus: 2 } },
      { state: 'parked', settings: { memoryMb: 8192, vcpus: 4 } },
    ])).toEqual({ running: 1, memoryMb: 12288, vcpus: 6 })
    expect(sharePercent(1, 0)).toBe(0)
  })
})
