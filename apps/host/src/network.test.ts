import { describe, expect, it } from 'vitest'
import { COMPUTERS_SUBNET, EXPANDED_SUBNET, FENCED_RANGES, MAX_SLOTS, fenceRules, networkSlot } from './network.js'

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
