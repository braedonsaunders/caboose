import { afterEach, describe, expect, it, vi } from 'vitest'
import { ComputerLifecycle } from './lifecycle.js'
import { authenticate } from './auth.js'

afterEach(() => vi.useRealTimers())

describe('computer lifecycle', () => {
  it('wakes for an operation and holds the computer until the operation finishes', async () => {
    vi.useFakeTimers()
    let finish!: () => void
    const driver = { wake: vi.fn(async () => 'desk'), park: vi.fn(async () => {}) }
    const computer = new ComputerLifecycle(driver, 100)
    const operation = computer.wakeAndRun(() => new Promise<void>(resolve => { finish = resolve }))
    await vi.waitFor(() => expect(finish).toBeDefined())
    await vi.advanceTimersByTimeAsync(200)
    expect(driver.wake).toHaveBeenCalledOnce()
    expect(driver.park).not.toHaveBeenCalled()
    finish()
    await operation
    await vi.advanceTimersByTimeAsync(100)
    expect(driver.park).toHaveBeenCalledOnce()
  })

  it('does not run work when waking fails and allows a later attempt', async () => {
    const driver = { wake: vi.fn().mockRejectedValueOnce(new Error('boot failed')).mockResolvedValue('desk'), park: vi.fn(async () => {}) }
    const computer = new ComputerLifecycle<string>(driver, 1000)
    const work = vi.fn(async () => 'saved')
    await expect(computer.wakeAndRun(work)).rejects.toThrow('boot failed')
    expect(work).not.toHaveBeenCalled()
    expect(await computer.wakeAndRun(work)).toBe('saved')
  })

  it('coalesces wakes and parks after the final lease expires', async () => {
    vi.useFakeTimers()
    const driver = { wake: vi.fn(async () => 'desk'), park: vi.fn(async () => {}) }
    const computer = new ComputerLifecycle(driver, 100)
    const states: string[] = []
    computer.subscribe(state => states.push(state))
    expect(await Promise.all([computer.wake(), computer.wake()])).toEqual(['desk', 'desk'])
    expect(driver.wake).toHaveBeenCalledTimes(1)
    const a = computer.acquire(), b = computer.acquire()
    await vi.advanceTimersByTimeAsync(200)
    a(); a()
    await vi.advanceTimersByTimeAsync(200)
    expect(driver.park).not.toHaveBeenCalled()
    b()
    await vi.advanceTimersByTimeAsync(100)
    expect(driver.park).toHaveBeenCalledTimes(1)
    expect(states).toEqual(['waking', 'running', 'parking', 'parked'])
    await computer.wake()
    expect(driver.wake).toHaveBeenCalledTimes(2)
  })

  it('serializes a wake behind an in-flight park', async () => {
    let complete!: () => void
    const driver = { wake: vi.fn(async () => 'desk'), park: vi.fn(() => new Promise<void>(r => { complete = r })) }
    const computer = new ComputerLifecycle(driver, 10000)
    await computer.wake()
    const parked = computer.park()
    await Promise.resolve()
    const waking = computer.wake()
    complete()
    await parked
    await waking
    expect(driver.wake).toHaveBeenCalledTimes(2)
    expect(computer.state).toBe('running')
  })

  it('reports failures and permits a later wake', async () => {
    const driver = { wake: vi.fn().mockRejectedValueOnce(new Error('boot failed')).mockResolvedValue('desk'), park: vi.fn(async () => {}) }
    const computer = new ComputerLifecycle<string>(driver, 1000)
    await expect(computer.wake()).rejects.toThrow('boot failed')
    expect(computer.state).toBe('error')
    expect(computer.lastError).toBe('boot failed')
    expect(await computer.wake()).toBe('desk')
    expect(computer.lastError).toBeNull()
  })

  it('waits for guest operations before restart, rejects duplicates and new operations', async () => {
    let finishOperation!: () => void
    let finishRestart!: (value: string) => void
    const driver = { wake: async () => 'initial', park: async () => {},
      restart: vi.fn(() => new Promise<string>(resolve => { finishRestart = resolve })) }
    const computer = new ComputerLifecycle(driver, 60000)
    await computer.wake()
    const operation = computer.run(() => new Promise<void>(resolve => { finishOperation = resolve }))
    await Promise.resolve()
    const restarting = computer.restart()
    expect(computer.acceptsConnections).toBe(false)
    await expect(computer.restart()).rejects.toThrow('already restarting')
    await expect(computer.run(async () => 'new operation')).rejects.toThrow('restarting')
    expect(driver.restart).not.toHaveBeenCalled()
    finishOperation()
    await operation
    await vi.waitFor(() => expect(driver.restart).toHaveBeenCalledTimes(1))
    expect(computer.state).toBe('restarting')
    finishRestart('fresh')
    expect(await restarting).toBe('fresh')
    expect(await computer.wake()).toBe('fresh')
    await computer.park()
  })

  it('rearms idle timeout when settings change and still respects leases', async () => {
    vi.useFakeTimers()
    const driver = { wake: async () => 'desk', park: vi.fn(async () => {}) }
    const computer = new ComputerLifecycle(driver, 1000)
    await computer.wake()
    const release = computer.acquire()
    computer.setIdleMs(100)
    await vi.advanceTimersByTimeAsync(200)
    expect(driver.park).not.toHaveBeenCalled()
    release()
    await vi.advanceTimersByTimeAsync(100)
    expect(driver.park).toHaveBeenCalledOnce()
  })

  it('exposes restart errors and permits recovery', async () => {
    const driver = { wake: async () => 'desk', park: async () => {}, restart: vi.fn().mockRejectedValueOnce(new Error('sync failed')).mockResolvedValue('recovered') }
    const computer = new ComputerLifecycle(driver, 60000)
    await expect(computer.restart()).rejects.toThrow('sync failed')
    expect(computer.state).toBe('error')
    expect(computer.lastError).toBe('sync failed')
    expect(await computer.restart()).toBe('recovered')
    expect(computer.lastError).toBeNull()
    await computer.park()
  })
})

describe('bearer authentication', () => {
  it('accepts only the owner bearer token', () => {
    expect(authenticate('Bearer secret', 'secret')).toBe(true)
    for (const header of [undefined, '', 'secret', 'Bearer ', 'Bearer secrets', 'bearer secret']) {
      expect(authenticate(header, 'secret')).toBe(false)
    }
    expect(authenticate('Bearer x', '')).toBe(false)
  })
})
