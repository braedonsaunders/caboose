import { describe, expect, it } from 'vitest'
import { crossSite } from './cross-site.js'
import { parseTrustedProxies } from './proxies.js'

const admin = { kind: 'admin' as const }
const request = (method: string, headers: Record<string, string>, address = '203.0.113.1') => ({ method, headers: { host: 'caboose.local:7310', ...headers }, socket: { remoteAddress: address } }) as never
const options = { trustedProxies: parseTrustedProxies('172.31.250.0/24'), publicUrl: 'https://caboose.example.com/caboose' }

describe('cross-site requests with a session cookie', () => {
  it('are refused unless the browser vouches for the page', () => {
    expect(crossSite(request('POST', { origin: 'https://evil.example' }), admin, options)).toBe(true)
    expect(crossSite(request('POST', { origin: 'https://evil.example', 'sec-fetch-site': 'cross-site' }), admin, options)).toBe(true)
    expect(crossSite(request('POST', { 'sec-fetch-site': 'same-site' }), admin, options)).toBe(true)
    expect(crossSite(request('POST', { origin: 'null' }), admin, options)).toBe(true)
    expect(crossSite(request('POST', {}), admin, options)).toBe(true)
    expect(crossSite(request('DELETE', { origin: 'http://caboose.local:7311' }), admin, options)).toBe(true)
    expect(crossSite(request('POST', { origin: 'http://caboose.local:7310' }), admin, options)).toBe(false)
    expect(crossSite(request('PATCH', { 'sec-fetch-site': 'same-origin' }), admin, options)).toBe(false)
    expect(crossSite(request('POST', { 'sec-fetch-site': 'none' }), admin, options)).toBe(false)
    expect(crossSite(request('POST', { origin: 'https://caboose.example.com' }), admin, options)).toBe(false)
    expect(crossSite(request('POST', { origin: 'https://caboose.example.com:443/' }), admin, options)).toBe(false)
    expect(crossSite(request('POST', { origin: 'http://caboose.example.com' }), admin, options)).toBe(true)
  })

  it('believe the scheme a trusted proxy forwarded, and nobody else', () => {
    const headers = { host: 'caboose.local', origin: 'https://caboose.local', 'x-forwarded-proto': 'https' }
    expect(crossSite(request('POST', headers, '172.31.250.9'), admin, options)).toBe(false)
    expect(crossSite(request('POST', headers, '127.0.0.1'), admin, options)).toBe(false)
    expect(crossSite(request('POST', headers, '203.0.113.1'), admin, options)).toBe(true)
  })

  it('leave reads, tokens and anonymous requests alone, but check every socket upgrade', () => {
    expect(crossSite(request('GET', { origin: 'https://evil.example' }), admin, options)).toBe(false)
    expect(crossSite(request('HEAD', { origin: 'https://evil.example' }), admin, options)).toBe(false)
    expect(crossSite(request('OPTIONS', {}), admin, options)).toBe(false)
    expect(crossSite(request('POST', { origin: 'https://evil.example' }), { kind: 'owner' }, options)).toBe(false)
    expect(crossSite(request('POST', {}), { kind: 'phone' }, options)).toBe(false)
    expect(crossSite(request('POST', { origin: 'https://evil.example' }), undefined, options)).toBe(false)
    expect(crossSite(request('GET', { origin: 'https://evil.example' }), admin, { ...options, upgrade: true })).toBe(true)
    expect(crossSite(request('GET', {}), admin, { ...options, upgrade: true })).toBe(true)
    expect(crossSite(request('GET', { origin: 'http://caboose.local:7310' }), admin, { ...options, upgrade: true })).toBe(false)
    expect(crossSite(request('GET', { 'sec-fetch-site': 'same-origin' }), admin, { ...options, upgrade: true })).toBe(false)
    expect(crossSite(request('GET', { origin: 'https://evil.example' }), { kind: 'owner' }, { ...options, upgrade: true })).toBe(false)
  })
})
