import { expect, it } from 'vitest'
import { parkedFileIdentity } from './parked-files-metadata.js'

it('preserves the guest device and exact nanosecond timestamps in identity and ETag', () => {
  const result = parkedFileIdentity(64769n, 123456789012345n, 456n, 1700000000123456789n, 1700000000987654321n)
  expect(result.identity).toBe('64769:123456789012345')
  expect(result.etag).toBe('"fa3810a71fafc75434130c52f01321f646b60a1cbbaeb2232f05aa6192eb4eb7"')
  expect(() => parkedFileIdentity(0n, -1n, 1n, 0n, 0n)).toThrow()
})
