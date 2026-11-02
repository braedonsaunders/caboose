import { describe, expect, it } from 'vitest'
import { config, parseVmFreePageReporting } from './config.js'

describe('parseVmFreePageReporting', () => {
  it('defaults to true when CABOOSE_VM_FREE_PAGE_REPORTING is unset or blank', () => {
    expect(parseVmFreePageReporting(undefined)).toBe(true)
    expect(parseVmFreePageReporting('')).toBe(true)
    expect(parseVmFreePageReporting('   ')).toBe(true)
    expect(config({}).vmFreePageReporting).toBe(true)
  })

  it('accepts explicit on and off values', () => {
    expect(parseVmFreePageReporting('on')).toBe(true)
    expect(parseVmFreePageReporting('off')).toBe(false)
    expect(config({ CABOOSE_VM_FREE_PAGE_REPORTING: 'on' }).vmFreePageReporting).toBe(true)
    expect(config({ CABOOSE_VM_FREE_PAGE_REPORTING: 'off' }).vmFreePageReporting).toBe(false)
  })

  it('rejects invalid values and explicit on in container mode', () => {
    expect(() => parseVmFreePageReporting('yes')).toThrow('CABOOSE_VM_FREE_PAGE_REPORTING must be on or off')
    expect(() => config({ CABOOSE_VM_FREE_PAGE_REPORTING: 'invalid' })).toThrow('CABOOSE_VM_FREE_PAGE_REPORTING must be on or off')
    expect(config({ CABOOSE_RUNTIME: 'container' }).vmFreePageReporting).toBe(false)
    expect(() => config({ CABOOSE_RUNTIME: 'container', CABOOSE_VM_FREE_PAGE_REPORTING: 'on' })).toThrow('Cloud Hypervisor memory options require the microVM runtime')
  })
})
