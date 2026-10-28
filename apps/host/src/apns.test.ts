import { generateKeyPairSync, verify } from 'node:crypto'
import { describe, expect, it } from 'vitest'
import { ProviderToken, apnsFromEnvironment } from './apns.js'

describe('APNs provider authentication', () => {
  it('signs an ES256 JWT and refreshes before an hour', () => {
    const { privateKey, publicKey } = generateKeyPairSync('ec', { namedCurve: 'prime256v1' })
    let now = 1_700_000_000_000
    const provider = new ProviderToken({ key: privateKey, keyId: 'KEY', teamId: 'TEAM', topic: 'example.app' }, () => now)
    const jwt = provider.get(), parts = jwt.split('.')
    expect(JSON.parse(Buffer.from(parts[0]!, 'base64url').toString())).toEqual({ alg: 'ES256', kid: 'KEY' })
    expect(JSON.parse(Buffer.from(parts[1]!, 'base64url').toString())).toEqual({ iss: 'TEAM', iat: now / 1000 })
    expect(verify('sha256', Buffer.from(`${parts[0]}.${parts[1]}`), { key: publicKey, dsaEncoding: 'ieee-p1363' }, Buffer.from(parts[2]!, 'base64url'))).toBe(true)
    now += 2_999_000
    expect(provider.get()).toBe(jwt)
    now += 1000
    expect(provider.get()).not.toBe(jwt)
    now -= 4_000_000
    expect(provider.get()).not.toBe(jwt)
  })
  it('rejects incomplete configuration', async () => {
    expect(await apnsFromEnvironment({})).toBeUndefined()
    await expect(apnsFromEnvironment({ CABOOSE_APNS_KEY_ID: 'KEY' })).rejects.toThrow('required')
  })
})
