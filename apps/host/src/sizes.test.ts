import { describe, expect, it } from 'vitest'
import { computerSizes, expandSize } from './sizes.js'

describe('computer sizes', () => {
  it('expands each preset and preserves unrelated fields', () => {
    expect(expandSize({ name: 'A', size: 'micro' }, false)).toEqual({ name: 'A', memoryMb: 2048, vcpus: 2 })
    expect(expandSize({ size: 'standard' }, false)).toEqual({ memoryMb: 4096, vcpus: 4 })
    expect(expandSize({ size: 'gpu' }, true)).toEqual({ memoryMb: 8192, vcpus: 8 })
  })
  it('rejects unavailable, unknown and ambiguous requests while retaining custom resources', () => {
    expect(computerSizes(false).find(size => size.id === 'gpu')?.available).toBe(false)
    expect(() => expandSize({ size: 'gpu' }, false)).toThrow(/GPU/)
    expect(() => expandSize({ size: 'unknown' }, true)).toThrow(/Unknown/)
    expect(() => expandSize({ size: 'micro', vcpus: 9 }, true)).toThrow(/cannot be combined/)
    expect(expandSize({ memoryMb: 3000, vcpus: 3 }, false)).toEqual({ memoryMb: 3000, vcpus: 3 })
  })
})
