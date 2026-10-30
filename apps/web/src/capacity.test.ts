import { expect, it } from 'vitest'
import { capacityValue } from './capacity.js'
it('formats bytes, counts and percentages without substituting zero for unavailable', () => {
  expect(capacityValue({ value: null, reason: 'not measured' }, 'bytes')).toBe('Unavailable: not measured')
  expect(capacityValue({ value: 1024 ** 3 }, 'bytes')).toBe('1.0 GiB')
  expect(capacityValue({ value: 4 })).toBe('4')
  expect(capacityValue({ value: 12.345 }, 'percent')).toBe('12.3%')
  expect(capacityValue({ value: -(1024 ** 3) }, 'bytes')).toBe('−1.0 GiB')
})
