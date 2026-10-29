import { describe, expect, it } from 'vitest'
import { templateNetworkFence } from './template-network.js'

describe('template network fence', () => {
  it('blocks both directions in IPv4 and IPv6 before release', async () => {
    const rules = new Set<string>(), calls: string[] = []
    const fence = templateNetworkFence(7, async (binary, args) => {
      const key = `${binary} ${args.slice(2).filter(arg => arg !== '1').join(' ')}`
      calls.push(`${binary} ${args.join(' ')}`)
      if (args[1] === '-I') rules.add(key)
      else if (args[1] === '-C' && !rules.has(key)) throw Object.assign(new Error('missing'), { code: 1 })
      else if (args[1] === '-D') rules.delete(key)
    })
    await fence.hold()
    expect(rules.size).toBe(8)
    expect(calls.some(call => call.includes('ip6tables -w -I OUTPUT 1 -o caboose7'))).toBe(true)
    await fence.release()
    expect(rules.size).toBe(0)
  })
  it('does not roll back a partially installed fence when installation fails', async () => {
    let calls = 0
    const fence = templateNetworkFence(1, async () => { if (++calls === 3) throw new Error('iptables unavailable') })
    await expect(fence.hold()).rejects.toThrow('iptables unavailable')
    expect(calls).toBe(3)
  })
})
