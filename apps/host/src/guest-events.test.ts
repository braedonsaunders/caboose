import { describe, expect, it, vi } from 'vitest'
import { GuestEvents, readEventResponse } from './guest-events.js'
const batch = (records: unknown[] = []) => new Response(JSON.stringify({ cursor: 'epoch:1', records }))
const record = { channel: 'phone', receipt: 'receipt', record: { id: 'one' } }
const flush = async () => { for (let i = 0; i < 30; i++) await Promise.resolve() }
const hold = (_url: unknown, init?: RequestInit) => new Promise<Response>((_resolve, reject) => init?.signal?.addEventListener('abort', () => reject(new Error('aborted'))))

describe('guest events receiver', () => {
  it('bounds bodies regardless of declared length and validates channels', async () => {
    await expect(readEventResponse(new Response('x'.repeat(2 * 1024 * 1024 + 1)))).rejects.toThrow('limit')
    await expect(readEventResponse(batch([{ ...record, channel: 'arbitrary/path' }]))).rejects.toThrow('Invalid')
    await expect(readEventResponse(batch([{ ...record, record: 'x'.repeat(1024 * 1024) }]))).rejects.toThrow('Invalid')
  })
  it('acknowledges only after consumer acceptance', async () => {
    let accept!: () => void
    const accepted = new Promise<void>(resolve => { accept = resolve })
    const transport = vi.fn().mockResolvedValueOnce(batch([record])).mockImplementation(hold)
    const events = new GuestEvents(() => ({ url: 'http://computer-one', token: 'one' }), () => [], transport)
    events.subscribe('phone', () => accepted)
    events.setRunning(true)
    await flush()
    expect(transport).toHaveBeenCalledTimes(1)
    accept(); await flush()
    expect(JSON.parse(transport.mock.calls[1]![1].body).acks).toEqual(['receipt'])
    events.stop(); await flush()
  })
  it('keeps rejected records unacknowledged for reconnect and never executes a guest command', async () => {
    vi.useFakeTimers()
    const transport = vi.fn().mockResolvedValueOnce(batch([record])).mockImplementation(hold)
    const events = new GuestEvents(() => ({ url: 'http://computer-one', token: 'one' }), () => [], transport)
    events.subscribe('phone', () => { throw new Error('consumer unavailable') })
    events.setRunning(true); await flush()
    await vi.advanceTimersByTimeAsync(1000)
    expect(JSON.parse(transport.mock.calls[1]![1].body)).toMatchObject({ cursor: '', acks: [] })
    events.stop(); await flush(); vi.useRealTimers()
  })
  it('fences late responses after stop and keeps computer credentials separate', async () => {
    let deliver!: (response: Response) => void
    const transport = vi.fn().mockImplementationOnce(() => new Promise<Response>(resolve => { deliver = resolve })).mockImplementation(hold)
    const accept = vi.fn()
    const events = new GuestEvents(() => ({ url: 'http://computer-one', token: 'one' }), () => [], transport)
    events.subscribe('phone', accept); events.setRunning(true); events.stop()
    deliver(batch([record])); await flush()
    expect(accept).not.toHaveBeenCalled()
    const other = new GuestEvents(() => ({ url: 'http://computer-two', token: 'two' }), () => [], transport)
    other.setRunning(true); await flush()
    expect(String(transport.mock.calls[1]![0])).toBe('http://computer-two/events')
    expect(transport.mock.calls[1]![1].headers.Authorization).toBe('Bearer two')
    other.stop(); await flush()
  })
  it('interrupts a wait to retire task watches and change phone presence', async () => {
    const transport = vi.fn().mockImplementation(hold)
    const events = new GuestEvents(() => ({ url: 'http://computer-one', token: 'one' }), () => [], transport)
    events.setRunning(true); await flush()
    events.setPhone(true); await flush()
    expect(transport.mock.calls[0]![1].signal.aborted).toBe(true)
    expect(JSON.parse(transport.mock.calls[1]![1].body).phone).toBe(true)
    events.stop(); await flush()
  })
  it('renews phone presence while a slow accepted callback blocks data acknowledgement', async () => {
    vi.useFakeTimers()
    let finish!: () => void
    const pending = new Promise<void>(resolve => { finish = resolve })
    const transport = vi.fn().mockImplementation((url, init) => {
      if (String(url).endsWith('/presence')) return Promise.resolve(new Response('{}'))
      if (transport.mock.calls.filter(([u]) => String(u).endsWith('/events')).length === 1) return Promise.resolve(batch([record]))
      return hold(url, init)
    })
    const events = new GuestEvents(() => ({ url: 'http://computer-one', token: 'one' }), () => [], transport)
    events.subscribe('phone', () => pending); events.setPhone(true); events.setRunning(true)
    await flush(); await vi.advanceTimersByTimeAsync(4000)
    expect(transport.mock.calls.filter(([u]) => String(u).endsWith('/presence')).length).toBeGreaterThanOrEqual(4)
    expect(transport.mock.calls.filter(([u]) => String(u).endsWith('/events'))).toHaveLength(1)
    events.stop(); finish(); await flush(); vi.useRealTimers()
  })

})
