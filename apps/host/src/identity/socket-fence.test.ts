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
    await Promise.resolve()
    release(true)
    await Promise.all([first, second])
    expect(valid).toHaveBeenCalledTimes(2)
    expect(close).toHaveBeenCalledOnce()
    fence.dispose()
  })
})

it('bounds a hung sweep and never schedules the unresolved validator again', async () => {
  vi.useFakeTimers()
  const fence = new AccountSocketFence(30_000, 100)
  const hung = vi.fn(() => new Promise<boolean>(() => {}))
  const close = vi.fn()
  fence.add(hung, close)
  const pending = fence.revalidate()
  await vi.advanceTimersByTimeAsync(100)
  await pending
  expect(close).toHaveBeenCalledOnce()
  await fence.revalidate()
  expect(hung).toHaveBeenCalledOnce()
  fence.dispose()
  expect(vi.getTimerCount()).toBe(0)
})

it('disposal closes sockets and releases an awaiting sweep without waiting for storage', async () => {
  vi.useFakeTimers()
  const fence = new AccountSocketFence()
  const close = vi.fn()
  fence.add(() => new Promise<boolean>(() => {}), close)
  const pending = fence.revalidate()
  fence.dispose()
  await pending
  expect(close).toHaveBeenCalledOnce()
  expect(vi.getTimerCount()).toBe(0)
})
