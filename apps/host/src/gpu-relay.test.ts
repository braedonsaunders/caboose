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
    constructor(..._args: unknown[]) { super(); state.created.push(this) }
    pause() { this.paused = true }
    resume() { this.paused = false }
    send(_data: unknown, _options: unknown, complete: (error?: Error) => void) { this.pending.push(complete) }
    terminate() { if (this.readyState !== 3) { this.readyState = 3; this.emit('close') } }
  }
  return { WebSocket: Socket }
})

import { WebSocket } from 'ws'
import { GPU_MAX_MESSAGE, GPU_MAX_PENDING, GPU_MAX_PENDING_MESSAGES, gpuUpstreamURL, relayGPU } from './gpu-relay.js'

type ControlledSocket = WebSocket & { pending: Array<(error?: Error) => void>; paused: boolean }
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
