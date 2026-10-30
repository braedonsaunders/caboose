import { describe, expect, it } from 'vitest'
import { config } from './config.js'
import { clientAddress, dropUntrustedForwarding, isTrustedProxy, parseTrustedProxies, requestOrigin } from './proxies.js'

const request = (address: string | undefined, headers: Record<string, string> = {}) => ({ headers, socket: { remoteAddress: address } }) as never

describe('trusted proxies', () => {
  it('parses addresses and ranges of both families, and refuses anything else', () => {
    const trusted = parseTrustedProxies(' 172.31.250.0/24,2001:db8::/32 , 203.0.113.9,::1 ')
    expect(trusted).toHaveLength(4)
    expect(isTrustedProxy('172.31.250.200', trusted)).toBe(true)
    expect(isTrustedProxy('::ffff:172.31.250.200', trusted)).toBe(true)
    expect(isTrustedProxy('172.31.251.1', trusted)).toBe(false)
    expect(isTrustedProxy('2001:db8:dead:beef::1', trusted)).toBe(true)
    expect(isTrustedProxy('2001:db9::1', trusted)).toBe(false)
    expect(isTrustedProxy('203.0.113.9', trusted)).toBe(true)
    expect(isTrustedProxy('203.0.113.10', trusted)).toBe(false)
    expect(isTrustedProxy('fe80::1%en0', parseTrustedProxies('fe80::/10'))).toBe(true)
    expect(isTrustedProxy('10.0.0.1', parseTrustedProxies('0.0.0.0/0'))).toBe(true)
    expect(isTrustedProxy('2001:db8::1', parseTrustedProxies('0.0.0.0/0'))).toBe(false)
    expect(isTrustedProxy('10.0.0.1', parseTrustedProxies('::/0'))).toBe(true)
    expect(parseTrustedProxies(undefined)).toEqual([])
    expect(parseTrustedProxies('')).toEqual([])
    for (const bad of ['proxy.example', '10.0.0.0/33', '::1/129', '10.0.0.1/8/8', '10.0.0.1/-1', '10.0.0.1/x', '1.2.3']) {
      expect(() => parseTrustedProxies(bad)).toThrow(/CABOOSE_TRUSTED_PROXIES/)
    }
    expect(() => config({ CABOOSE_TRUSTED_PROXIES: '10.0.0.0/8, nope' })).toThrow(/"nope"/)
    expect(config({ CABOOSE_TRUSTED_PROXIES: '10.0.0.0/8' }).trustedProxies).toHaveLength(1)
    expect(config({}).trustedProxies).toEqual([])
  })

  it('always trusts loopback and nothing that is not an address', () => {
    expect(isTrustedProxy('127.0.0.1', [])).toBe(true)
    expect(isTrustedProxy('127.8.8.8', [])).toBe(true)
    expect(isTrustedProxy('::1', [])).toBe(true)
    expect(isTrustedProxy('::ffff:127.0.0.1', [])).toBe(true)
    expect(isTrustedProxy('192.168.1.1', [])).toBe(false)
    expect(isTrustedProxy('unknown', [])).toBe(false)
    expect(isTrustedProxy(undefined, [])).toBe(false)
  })
})

describe('the client address', () => {
  const trusted = parseTrustedProxies('172.31.250.0/24')

  it('is the peer unless the peer is a trusted proxy', () => {
    expect(clientAddress(request('203.0.113.1'), trusted)).toBe('203.0.113.1')
    expect(clientAddress(request('203.0.113.1', { 'x-forwarded-for': '198.51.100.7' }), trusted)).toBe('203.0.113.1')
    expect(clientAddress(request(undefined), trusted)).toBe('unknown')
    expect(clientAddress(request('::ffff:203.0.113.1'), trusted)).toBe('203.0.113.1')
    expect(clientAddress(request('2001:db8::7'), trusted)).toBe('2001:db8::7')
  })

  it('is the last hop a trusted proxy did not add itself', () => {
    expect(clientAddress(request('172.31.250.2', { 'x-forwarded-for': '198.51.100.7' }), trusted)).toBe('198.51.100.7')
    expect(clientAddress(request('127.0.0.1', { 'x-forwarded-for': '198.51.100.7' }), trusted)).toBe('198.51.100.7')
    expect(clientAddress(request('172.31.250.2', { 'x-forwarded-for': '10.1.1.1, 198.51.100.7, 172.31.250.3' }), trusted)).toBe('198.51.100.7')
    expect(clientAddress(request('172.31.250.2', { 'x-forwarded-for': '::ffff:198.51.100.7' }), trusted)).toBe('198.51.100.7')
    expect(clientAddress(request('172.31.250.2', { 'x-forwarded-for': '2001:db8::9, 127.0.0.1' }), trusted)).toBe('2001:db8::9')
    // Nothing forwarded, or only our own proxies: the proxy itself is the client.
    expect(clientAddress(request('172.31.250.2'), trusted)).toBe('172.31.250.2')
    expect(clientAddress(request('172.31.250.2', { 'x-forwarded-for': '172.31.250.3' }), trusted)).toBe('172.31.250.3')
  })
})

describe('the request origin', () => {
  const trusted = parseTrustedProxies('172.31.250.0/24')

  it('is plain HTTP at the Host header unless a trusted proxy says HTTPS', () => {
    expect(requestOrigin(request('203.0.113.1', { host: 'caboose.local:7310' }), trusted)).toBe('http://caboose.local:7310')
    expect(requestOrigin(request('203.0.113.1', { host: 'caboose.example.com', 'x-forwarded-proto': 'https' }), trusted)).toBe('http://caboose.example.com')
    expect(requestOrigin(request('172.31.250.2', { host: 'caboose.example.com', 'x-forwarded-proto': 'https' }), trusted)).toBe('https://caboose.example.com')
    expect(requestOrigin(request('172.31.250.2', { host: 'caboose.example.com:443', 'x-forwarded-proto': 'https, http' }), trusted)).toBe('https://caboose.example.com')
    expect(requestOrigin(request('172.31.250.2', { host: 'caboose.example.com', 'x-forwarded-proto': 'http' }), trusted)).toBe('http://caboose.example.com')
    expect(requestOrigin(request('127.0.0.1', { host: '[::1]:7310', 'x-forwarded-proto': 'https' }), trusted)).toBe('https://[::1]:7310')
    expect(requestOrigin(request('203.0.113.1'), trusted)).toBeNull()
    expect(requestOrigin(request('203.0.113.1', { host: 'not a host' }), trusted)).toBeNull()
  })

  it('drops forwarding headers from a peer that is not a trusted proxy', () => {
    const direct = request('203.0.113.1', { host: 'h', 'x-forwarded-for': '1.1.1.1', 'x-forwarded-proto': 'https', 'x-forwarded-host': 'evil', other: 'kept' }) as { headers: Record<string, string> }
    dropUntrustedForwarding(direct as never, trusted)
    expect(direct.headers).toEqual({ host: 'h', other: 'kept' })
    const proxied = request('172.31.250.2', { 'x-forwarded-for': '1.1.1.1', 'x-forwarded-proto': 'https' }) as { headers: Record<string, string> }
    dropUntrustedForwarding(proxied as never, trusted)
    expect(proxied.headers).toEqual({ 'x-forwarded-for': '1.1.1.1', 'x-forwarded-proto': 'https' })
  })
})
