import { describe, expect, it } from 'vitest'
import { COMPUTERS_SUBNET, EXPANDED_SUBNET, FENCED_RANGES, MAX_SLOTS, fenceRules, networkSlot, createNetworkCache } from './network.js'

describe('fenceRules', () => {
  it('lets the guest answer the host but open nothing on it', () => {
    const { input } = fenceRules(false)
    expect(input[0]).toContain('ESTABLISHED,RELATED')
    expect(input.at(-1)).toEqual(['-j', 'DROP'])
  })

  it('rejects other computers, then private, metadata and tailnet destinations, before anything is forwarded', () => {
    const { forward } = fenceRules(false)
    const rejected = forward.filter(rule => rule.includes('REJECT')).map(rule => rule[1])
    expect(rejected).toEqual([COMPUTERS_SUBNET, EXPANDED_SUBNET, ...FENCED_RANGES])
    expect(rejected).toEqual(expect.arrayContaining(['10.0.0.0/8', '192.168.0.0/16', '169.254.0.0/16', '100.64.0.0/10']))
    expect(forward.at(-1)).toEqual(['-j', 'RETURN'])
  })

  it('opens the LAN only when asked, and never the other computers', () => {
    const rejected = fenceRules(true).forward.filter(rule => rule.includes('REJECT')).map(rule => rule[1])
    expect(rejected).toEqual([COMPUTERS_SUBNET, EXPANDED_SUBNET])
    expect(fenceRules(true).input.at(-1)).toEqual(['-j', 'DROP'])
  })
})

describe('networkSlot', () => {
  it("keeps the owner's computer on the addresses a single-computer host used", () => {
    expect(networkSlot(0)).toEqual({ tap: 'caboose0', host: '192.0.2.1', guest: '192.0.2.2' })
  })

  it('gives every computer its own /30 inside the fenced subnet', () => {
    expect(networkSlot(1)).toEqual({ tap: 'caboose1', host: '192.0.2.5', guest: '192.0.2.6' })
    expect(networkSlot(63)).toEqual({ tap: 'caboose63', host: '192.0.2.253', guest: '192.0.2.254' })
    expect(networkSlot(64)).toEqual({ tap: 'caboose64', host: '198.18.0.1', guest: '198.18.0.2' })
    expect(networkSlot(MAX_SLOTS - 1)).toEqual({ tap: `caboose${MAX_SLOTS - 1}`, host: '198.19.255.253', guest: '198.19.255.254' })
    const guests = Array.from({ length: MAX_SLOTS }, (_, slot) => networkSlot(slot).guest)
    expect(new Set(guests).size).toBe(MAX_SLOTS)
    expect(() => networkSlot(MAX_SLOTS)).toThrow()
    expect(() => networkSlot(-1)).toThrow()
    expect(() => networkSlot(1.5)).toThrow()
  })
})


it('reuses only unchanged verified network state and invalidates after errors and deletion', async () => {
  let state = 'kernel-1', calls = 0, fail = false
  const cache = createNetworkCache(async () => { calls++; if (fail) throw new Error('setup failed') }, async () => state)
  await cache.ensure(0)
  await cache.ensure(0)
  expect(calls).toBe(1)
  state = 'rules changed'
  await cache.ensure(0)
  expect(calls).toBe(2)
  cache.invalidate(0)
  fail = true
  await expect(cache.ensure(0)).rejects.toThrow('setup failed')
  fail = false
  await cache.ensure(0)
  expect(calls).toBe(4)
})

it('ignores snapshot timestamps, counters and elapsed lifetimes but detects firewall and TAP changes', async () => {
  const { networkStateFingerprint } = await import('./network.js')
  let packets = 1, lifetime = 300, address = '192.0.2.1', target = 'DROP', setups = 0
  const fingerprint = async () => networkStateFingerprint(
    JSON.stringify([{ ifname: 'caboose0', flags: ['UP'], stats64: { rx: { packets } }, addr_info: [{ local: address, prefixlen: 30, valid_life_time: lifetime, preferred_life_time: lifetime }] }]),
    `# Generated on ${packets}\n*filter\n:INPUT ACCEPT [${packets}:999]\n[${packets}:500] -A INPUT -j ${target}\nCOMMIT\n# Completed on ${packets}\n\n`, '1\n')
  const cache = createNetworkCache(async () => { setups++ }, fingerprint)
  await cache.ensure(0)
  packets = 200; lifetime = 150
  await cache.ensure(0)
  expect(setups).toBe(1)
  target = 'ACCEPT'
  await cache.ensure(0)
  expect(setups).toBe(2)
  address = '192.0.2.5'
  await cache.ensure(0)
  expect(setups).toBe(3)
  lifetime = 0
  await cache.ensure(0)
  expect(setups).toBe(4)
})
