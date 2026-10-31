import { expect, it, vi } from 'vitest'

const state = vi.hoisted(() => ({ created: [] as unknown[] }))
vi.mock('ws', async () => {
  const { EventEmitter } = await import('node:events')
  class Socket extends EventEmitter {
    static OPEN = 1
    static CLOSED = 3
    readyState = 1
    protocol = 'caboose.gpu.live.v1'
    pending: Array<(error?: Error) => void> = []
    paused = false
    closeCodes: number[] = []
    close(code: number) { this.closeCodes.push(code); this.readyState = 2 }
    peerClose(code: number) { this.readyState = 3; this.emit('close', code) }
    args: unknown[]
    constructor(...args: unknown[]) { super(); this.args = args; state.created.push(this) }
    pause() { this.paused = true }
    resume() { this.paused = false }
    send(_data: unknown, _options: unknown, complete: (error?: Error) => void) { this.pending.push(complete) }
    terminate() { if (this.readyState !== 3) { this.readyState = 3; this.emit('close') } }
  }
  return { WebSocket: Socket }
})

import { WebSocket } from 'ws'
import { GPU_CLOSE_TIMEOUT_MS, GPU_MAX_MESSAGE, GPU_MAX_PENDING, GPU_MAX_PENDING_MESSAGES, gpuFeatures, gpuUpstreamURL, relayGPU } from './gpu-relay.js'

type ControlledSocket = WebSocket & { pending: Array<(error?: Error) => void>; paused: boolean; closeCodes: number[]; peerClose(code: number): void }
function pair() {
  const client = new WebSocket('ws://test') as ControlledSocket
  const done = relayGPU(client, { displayURL: 'ws://guest:14600', displayToken: 'test', computer: 'owner', executor: 'test' })
  const upstream = state.created.at(-1) as ControlledSocket
  upstream.emit('open')
  return { client, upstream, done }
}

it('derives only the fixed guest path and refuses embedded credentials', () => {
  expect(gpuUpstreamURL('wss://guest:14600/display?arbitrary=1#fragment')).toBe('wss://guest:14600/gpu')
  expect(() => gpuUpstreamURL('https://guest')).toThrow()
  expect(() => gpuUpstreamURL('ws://secret@guest')).toThrow()
})

it('caps already-parsed messages even when pausing cannot retract queued callbacks', async () => {
  const { client, upstream, done } = pair()
  for (let i = 0; i < GPU_MAX_PENDING / GPU_MAX_MESSAGE; i++) client.emit('message', Buffer.alloc(GPU_MAX_MESSAGE), true)
  expect(client.paused).toBe(true)
  expect(upstream.pending).toHaveLength(4)
  client.emit('message', Buffer.from([1]), true)
  await done
  expect(client.readyState).toBe(WebSocket.CLOSED)
  expect(upstream.readyState).toBe(WebSocket.CLOSED)
  expect(upstream.pending).toHaveLength(4)
})

it('keeps reply progress independent from a stalled command direction', async () => {
  const { client, upstream, done } = pair()
  client.emit('message', Buffer.from([1]), true)
  expect(client.paused).toBe(true)
  upstream.emit('message', Buffer.from([2]), true)
  expect(client.pending).toHaveLength(1)
  client.pending.shift()!()
  expect(upstream.paused).toBe(false)
  expect(client.paused).toBe(true)
  upstream.pending.shift()!()
  expect(client.paused).toBe(false)
  client.terminate()
  await done
})

it('bounds queued empty messages as well as bytes', async () => {
  const { client, upstream, done } = pair()
  for (let i = 0; i <= GPU_MAX_PENDING_MESSAGES; i++) client.emit('message', Buffer.alloc(0), true)
  await done
  expect(upstream.pending).toHaveLength(GPU_MAX_PENDING_MESSAGES)
  expect(client.readyState).toBe(WebSocket.CLOSED)
})

it('closes both directions when a queued send fails', async () => {
  const { client, upstream, done } = pair()
  upstream.emit('message', Buffer.from([2]), true)
  client.pending.shift()!(new Error('connection lost'))
  await done
  expect(client.readyState).toBe(WebSocket.CLOSED)
  expect(upstream.readyState).toBe(WebSocket.CLOSED)
})


it('forwards normal close and waits for both socket handshakes', async () => {
  const { client, upstream, done } = pair()
  let finished = false
  void done.then(() => { finished = true })
  upstream.peerClose(1000)
  expect(client.closeCodes).toEqual([1000])
  expect(client.paused).toBe(false)
  await Promise.resolve()
  expect(finished).toBe(false)
  client.peerClose(1000)
  await done
  expect(finished).toBe(true)
})

it('bounds a peer that never acknowledges normal close', async () => {
  vi.useFakeTimers()
  try {
    const { client, upstream, done } = pair()
    upstream.peerClose(1000)
    expect(client.closeCodes).toEqual([1000])
    await vi.advanceTimersByTimeAsync(GPU_CLOSE_TIMEOUT_MS)
    await done
    expect(client.readyState).toBe(WebSocket.CLOSED)
  } finally { vi.useRealTimers() }
})

it('does not turn abnormal upstream closure into a normal receipt', async () => {
  const { client, upstream, done } = pair()
  upstream.peerClose(1006)
  await done
  expect(client.closeCodes).toEqual([])
  expect(client.readyState).toBe(WebSocket.CLOSED)
})

it('forwards only known phone GPU features, normalized', () => {
  expect(gpuFeatures(' Guest-Handles , bogus,guest-handles')).toEqual(['guest-handles'])
  expect(gpuFeatures(['x', 'guest-handles'])).toEqual(['guest-handles'])
  expect(gpuFeatures(undefined)).toEqual([])
  expect(gpuFeatures('completion-feed, guest-handle-arrays,GUEST-HANDLES')).toEqual(['completion-feed', 'guest-handle-arrays', 'guest-handles'])
  const client = new WebSocket('ws://test') as ControlledSocket
  void relayGPU(client, { displayURL: 'ws://guest:14600', displayToken: 't', computer: 'owner', executor: 'e', features: ['guest-handles'] })
  const withFeatures = state.created.at(-1) as unknown as { args: [string, string, { headers: Record<string, string> }] }
  expect(withFeatures.args[2].headers['x-caboose-gpu-features']).toBe('guest-handles')
  void relayGPU(new WebSocket('ws://test'), { displayURL: 'ws://guest:14600', displayToken: 't', computer: 'owner', executor: 'e' })
  const without = state.created.at(-1) as unknown as { args: [string, string, { headers: Record<string, string> }] }
  expect(without.args[2].headers).not.toHaveProperty('x-caboose-gpu-features')
})
