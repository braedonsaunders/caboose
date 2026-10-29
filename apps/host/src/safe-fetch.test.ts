import { createServer } from 'node:http'
import type { AddressInfo } from 'node:net'
import { describe, expect, it } from 'vitest'
import { fetchSafe, isPublicAddress, publicAddress, safeUrl, UnsafeAddressError } from './safe-fetch.js'

describe('addresses from untrusted metadata', () => {
  it('counts only public addresses, including IPv4 hidden in IPv6', () => {
    for (const address of ['8.8.8.8', '1.1.1.1', '2606:4700:4700::1111']) expect(isPublicAddress(address), address).toBe(true)
    for (const address of ['127.0.0.1', '10.1.2.3', '172.16.0.1', '192.168.1.1', '169.254.169.254', '100.64.0.1', '0.0.0.0', '224.0.0.1', '198.18.0.1',
      '::1', '::', 'fe80::1', 'fd00::1', 'fc00::1', 'ff02::1', '::ffff:127.0.0.1', '::ffff:7f00:1', '::ffff:8.8.8.8', '64:ff9b::a00:1', '2001:db8::1', 'not an address']) {
      expect(isPublicAddress(address), address).toBe(false)
    }
  })
  it('refuses a name when any address it resolves to is private', async () => {
    const resolve = (answers: Record<string, string[]>) => async (host: string) => (answers[host] ?? []).map(address => ({ address, family: address.includes(':') ? 6 : 4 }))
    const dns = resolve({ 'good.example': ['93.184.216.34'], 'mixed.example': ['93.184.216.34', '10.0.0.5'], 'six.example': ['::ffff:192.168.0.1'] })
    expect(await publicAddress('good.example', dns)).toEqual({ address: '93.184.216.34', family: 4 })
    await expect(publicAddress('mixed.example', dns)).rejects.toBeInstanceOf(UnsafeAddressError)
    await expect(publicAddress('six.example', dns)).rejects.toThrow('not on the public internet')
    await expect(publicAddress('missing.example', dns)).rejects.toThrow('could not be found')
    await expect(publicAddress('127.0.0.1')).rejects.toThrow('not on the public internet')
    await expect(publicAddress('[::1]')).rejects.toThrow('not on the public internet')
  })
  it('accepts only plain https URLs', () => {
    expect(safeUrl('https://example.com/a?b=c').hostname).toBe('example.com')
    for (const url of ['http://example.com', 'file:///etc/passwd', 'https://user:pass@example.com', 'javascript:alert(1)', 'nonsense']) expect(() => safeUrl(url), url).toThrow(UnsafeAddressError)
  })
  it('never connects to a private address, whatever the name says', async () => {
    const server = createServer((_request, response) => response.end('reached'))
    await new Promise<void>(resolve => server.listen(0, '127.0.0.1', resolve))
    try {
      const port = (server.address() as AddressInfo).port
      await expect(fetchSafe(`https://localhost.example:${port}/`, 1000, {}, async () => [{ address: '127.0.0.1', family: 4 }])).rejects.toThrow('not on the public internet')
    } finally { server.close() }
  })
})
