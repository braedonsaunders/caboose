import { afterEach, describe, expect, it, vi } from 'vitest'
import { AccountSocketFence } from './socket-fence.js'

afterEach(() => { vi.useRealTimers() })
describe('administrator socket authorization', () => {
  it('closes revoked memberships and sessions before mutation revalidation completes', async () => {
    const fence = new AccountSocketFence()
    let authorized = true
    const close = vi.fn()
    const remove = fence.add(async () => authorized, close)
    await fence.revalidate()
    expect(close).not.toHaveBeenCalled()
    authorized = false
    await fence.revalidate()
    expect(close).toHaveBeenCalledOnce()
    remove(); fence.dispose()
    expect(close).toHaveBeenCalledOnce()
  })
  it('checks expiry periodically, fails closed on database errors and releases timers', async () => {
    vi.useFakeTimers()
    const fence = new AccountSocketFence(30_000)
    const close = vi.fn()
    fence.add(async () => { throw new Error('unavailable') }, close)
    await vi.advanceTimersByTimeAsync(30_000)
    expect(close).toHaveBeenCalledOnce()
    fence.dispose()
    expect(vi.getTimerCount()).toBe(0)
  })
  it('rechecks an authorization change that races an in-flight read', async () => {
    const fence = new AccountSocketFence()
    let release!: (value: boolean) => void
    const valid = vi.fn().mockImplementationOnce(() => new Promise<boolean>(resolve => { release = resolve })).mockResolvedValue(false)
    const close = vi.fn()
    fence.add(valid, close)
    const first = fence.revalidate()
    const second = fence.revalidate()
    release(true)
    await Promise.all([first, second])
    expect(valid).toHaveBeenCalledTimes(2)
    expect(close).toHaveBeenCalledOnce()
    fence.dispose()
  })
})
