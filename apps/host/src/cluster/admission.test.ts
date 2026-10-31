import { expect, it, vi } from 'vitest'
import { ComputerAdmission } from './admission.js'

it('times out maintenance without releasing exclusion over a handler still mutating', async () => {
  vi.useFakeTimers()
  try {
    const gate = new ComputerAdmission(50), cancel = vi.fn(), capture = vi.fn()
    const done = gate.enter('a', cancel)
    const maintenance = gate.runExclusive('a',capture)
    const refused = expect(maintenance).rejects.toThrow('deadline')
    expect(cancel).toHaveBeenCalledOnce()
    await vi.advanceTimersByTimeAsync(50); await refused
    expect(capture).not.toHaveBeenCalled()
    expect(()=>gate.enter('a',()=>{})).toThrow('maintenance')
    gate.enter('b',()=>{})()
    done(); await Promise.resolve(); await Promise.resolve()
    gate.enter('a',()=>{})()
  } finally { vi.useRealTimers() }
})
