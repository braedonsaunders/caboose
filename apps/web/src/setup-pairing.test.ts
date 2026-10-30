import { describe, expect, it, vi } from 'vitest'
import { beginSetupPairing, joinedPhone } from './setup-pairing.js'
import type { PhoneSignIn } from './api.js'

const phone = (id: string): PhoneSignIn => ({ id, name: id, createdAt: '2026-10-29T00:00:00Z', lastUsedAt: null })

describe('first-run pairing', () => {
  it('captures existing phones before minting and detects an immediate scan', async () => {
    const order: string[] = []
    const client = {
      phones: vi.fn(async (id: string) => { expect(id).toBe('owner'); order.push('baseline'); return { phones: [phone('old')] } }),
      startPairing: vi.fn(async (id: string) => { expect(id).toBe('owner'); order.push('mint'); return { code: 'ABCD2345', expiresAt: '2026-10-29T00:10:00Z' } }),
      reach: vi.fn(async () => { throw new Error('unavailable') }),
    }
    const state = await beginSetupPairing(client)
    expect(order).toEqual(['baseline', 'mint'])
    expect(state.reach).toBeNull()
    expect(joinedPhone(state, [phone('old')])).toBeUndefined()
    expect(joinedPhone(state, [phone('old'), phone('new')])?.name).toBe('new')
  })

  it('does not mistake existing phones for new ones when baseline loading fails', async () => {
    const startPairing = vi.fn()
    await expect(beginSetupPairing({ phones: async () => { throw new Error('offline') }, startPairing, reach: vi.fn() })).rejects.toThrow('offline')
    expect(startPairing).not.toHaveBeenCalled()
  })

  it('surfaces a mint failure so retry never repeats account creation', async () => {
    await expect(beginSetupPairing({ phones: async () => ({ phones: [] }), startPairing: async () => { throw new Error('denied') }, reach: vi.fn(async () => null as never) })).rejects.toThrow('denied')
  })
})
