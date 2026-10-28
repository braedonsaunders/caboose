import { describe, expect, it } from 'vitest'
import { buildPairingLink, type Reach } from './api.js'
import { addressLabel, awayFromHome, pairingAddresses, tailscaleGuidance } from './remote-access.js'

const tailscale: Reach['tailscale'] = { installed: true, loggedIn: true, name: 'studio.tail1234.ts.net', serving: false }
const reach = (addresses: Reach['addresses'], ts: Reach['tailscale'] = tailscale): Reach => ({ addresses, mdns: { enabled: true, name: 'Studio' }, tailscale: ts })
const lan = { url: 'http://192.168.1.20:7310', kind: 'lan' as const }

describe('pairing addresses', () => {
  it('uses the host list and never a loopback console address', () => {
    expect(pairingAddresses(reach([lan]), 'http://localhost:7310')).toEqual(['http://192.168.1.20:7310'])
    expect(pairingAddresses(reach([lan]), 'http://127.0.0.1:7310/')).toEqual(['http://192.168.1.20:7310'])
    expect(pairingAddresses(reach([]), 'http://localhost:7310')).toEqual([])
  })

  it('adds the console address a phone could use, HTTPS first', () => {
    expect(pairingAddresses(reach([lan]), 'https://caboose.example.com')).toEqual(['https://caboose.example.com', 'http://192.168.1.20:7310'])
    expect(pairingAddresses(reach([lan]), 'http://10.0.0.7:7310')).toEqual(['http://192.168.1.20:7310', 'http://10.0.0.7:7310'])
    expect(pairingAddresses(reach([{ url: 'https://caboose.example.com', kind: 'public' }, lan]), 'https://caboose.example.com/')).toEqual(['https://caboose.example.com', 'http://192.168.1.20:7310'])
  })

  it('falls back to the console address when the host cannot say', () => {
    expect(pairingAddresses(null, 'http://192.168.1.20:7310')).toEqual(['http://192.168.1.20:7310'])
  })

  it('puts the first in host and the rest in alt', () => {
    expect(buildPairingLink(['https://studio.tail1234.ts.net', 'http://192.168.1.20:7310'], 'ABCD2345'))
      .toBe('caboose://connect?host=https%3A%2F%2Fstudio.tail1234.ts.net&alt=http%3A%2F%2F192.168.1.20%3A7310&code=ABCD2345')
    expect(buildPairingLink('http://192.168.1.20:7310/', ' ABCD2345 ')).toBe('caboose://connect?host=http%3A%2F%2F192.168.1.20%3A7310&code=ABCD2345')
  })
})

describe('Tailscale guidance', () => {
  it('walks through each state to the next step', () => {
    expect(tailscaleGuidance({ installed: false, loggedIn: false, serving: false })).toMatchObject({ tone: 'info', link: { href: 'https://tailscale.com/download' } })
    expect(tailscaleGuidance({ installed: true, loggedIn: false, serving: false, error: 'Tailscale is signed out on this machine' }))
      .toMatchObject({ tone: 'warning', title: 'Tailscale is signed out' })
    expect(tailscaleGuidance({ ...tailscale, error: 'HTTPS certificates are not enabled for this tailnet; turn on MagicDNS and HTTPS at https://login.tailscale.com/admin/dns' }))
      .toMatchObject({ tone: 'warning', link: { href: 'https://login.tailscale.com/admin/dns' } })
    expect(tailscaleGuidance({ ...tailscale, error: 'Tailscale already serves something else on HTTPS port 443' }).link).toBeUndefined()
    expect(tailscaleGuidance(tailscale)).toMatchObject({ tone: 'info', detail: expect.stringContaining('https://studio.tail1234.ts.net') })
    expect(tailscaleGuidance({ ...tailscale, serving: true, httpsUrl: 'https://studio.tail1234.ts.net' })).toMatchObject({ tone: 'success' })
  })
})

describe('away from home', () => {
  it('says how a phone away from home gets in', () => {
    expect(awayFromHome(reach([{ url: 'https://c.example.com', kind: 'public' }, lan])).tone).toBe('success')
    expect(awayFromHome(reach([{ url: 'https://studio.tail1234.ts.net', kind: 'tailscale' }, lan])).title).toMatch(/tailnet/)
    expect(awayFromHome(reach([lan]))).toMatchObject({ tone: 'info', detail: expect.stringMatching(/Never forward/) })
    expect(awayFromHome(reach([]))).toMatchObject({ tone: 'warning', detail: expect.stringContaining('CABOOSE_BIND=0.0.0.0') })
  })

  it('labels each kind of address', () => {
    expect([addressLabel('public'), addressLabel('tailscale'), addressLabel('lan')]).toEqual(['Your domain', 'Tailscale', 'Local network'])
  })
})
