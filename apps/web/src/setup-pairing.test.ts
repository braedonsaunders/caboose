import { describe, expect, it, vi } from 'vitest'
import { CabooseClient, type PhoneSignIn } from './api.js'
import { beginSetupPairing, joinedPhone } from './setup-pairing.js'

const phone = (id: string): PhoneSignIn => ({ id, name: id, createdAt: '2026-10-29T00:00:00Z', lastUsedAt: null })

describe('first-run pairing', () => {
  it('captures existing host phones before minting and detects an immediate scan', async () => {
    const order: string[] = []
    const client = {
      hostPhones: vi.fn(async () => { order.push('baseline'); return { phones: [phone('old')] } }),
      startHostPairing: vi.fn(async () => { order.push('mint'); return { code: 'ABCD2345', expiresAt: '2026-10-29T00:10:00Z' } }),
      reach: vi.fn(async () => { throw new Error('unavailable') }),
    }
    const state = await beginSetupPairing(client)
    expect(order).toEqual(['baseline', 'mint'])
    expect(state.reach).toBeNull()
    expect(joinedPhone(state, [phone('old')])).toBeUndefined()
    expect(joinedPhone(state, [phone('old'), phone('new')])?.name).toBe('new')
  })

  it('pairs with the host itself, never with a computer', async () => {
    const seen: Array<{ method: string; url: string }> = []
    const client = new CabooseClient(() => '', '', async (url, init) => {
      seen.push({ method: init?.method ?? 'GET', url: String(url) })
      if (String(url) === '/v1/host/pairing') return new Response('{"code":"ABCD2345","expiresAt":"2026-10-29T00:10:00Z"}', { status: 201 })
      if (String(url) === '/v1/host/phones') return new Response('{"phones":[]}', { status: 200 })
      return new Response('{"error":"no"}', { status: 404 })
    })
    const state = await beginSetupPairing(client)
    expect(state.code.code).toBe('ABCD2345')
    expect(seen).toEqual([
      { method: 'GET', url: '/v1/host/phones' },
      { method: 'POST', url: '/v1/host/pairing' },
      { method: 'GET', url: '/v1/host/reach' },
    ])
  })

  it('does not mistake existing phones for new ones when baseline loading fails', async () => {
    const startHostPairing = vi.fn()
    await expect(beginSetupPairing({ hostPhones: async () => { throw new Error('offline') }, startHostPairing, reach: vi.fn() })).rejects.toThrow('offline')
    expect(startHostPairing).not.toHaveBeenCalled()
  })

  it('surfaces a mint failure so retry never repeats account creation', async () => {
    await expect(beginSetupPairing({ hostPhones: async () => ({ phones: [] }), startHostPairing: async () => { throw new Error('denied') }, reach: vi.fn(async () => null as never) })).rejects.toThrow('denied')
  })
})
