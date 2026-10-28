import { describe, expect, it } from 'vitest'
import { FENCED_RANGES, fenceRules } from './network.js'

describe('fenceRules', () => {
  it('lets the guest answer the host but open nothing on it', () => {
    const { input } = fenceRules(false)
    expect(input[0]).toContain('ESTABLISHED,RELATED')
    expect(input.at(-1)).toEqual(['-j', 'DROP'])
  })

  it('rejects private, metadata and tailnet destinations before anything is forwarded', () => {
    const { forward } = fenceRules(false)
    const rejected = forward.filter(rule => rule.includes('REJECT')).map(rule => rule[1])
    expect(rejected).toEqual(FENCED_RANGES)
    expect(rejected).toEqual(expect.arrayContaining(['10.0.0.0/8', '192.168.0.0/16', '169.254.0.0/16', '100.64.0.0/10']))
    expect(forward.at(-1)).toEqual(['-j', 'RETURN'])
  })

  it('opens the LAN only when asked', () => {
    expect(fenceRules(true).forward.some(rule => rule.includes('REJECT'))).toBe(false)
    expect(fenceRules(true).input.at(-1)).toEqual(['-j', 'DROP'])
  })
})
