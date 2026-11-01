import { once } from 'node:events'
import { createServer, type IncomingMessage } from 'node:http'
import type { AddressInfo } from 'node:net'
import { WebSocket, WebSocketServer } from 'ws'
import { afterEach, describe, expect, it, vi } from 'vitest'
import { parseAiModels, parseAiRequest, parseGuestMessage, parsePhoneMessage } from './ai.js'
import { createCabooseServer, type Controller } from './server.js'
import { SettingsStore, settingsLimits } from './settings.js'

const close: Array<() => Promise<void> | void> = []
afterEach(async () => { for (const f of close.splice(0).reverse()) await f() })

const ID = 'a'.repeat(32)
const MODEL = { id: 'apple-foundation', name: 'Apple Foundation Model', contextSize: 4096, capabilities: ['tools', 'json'], ownedBy: 'apple' }

describe('Caboose AI messages', () => {
  it('re-encodes a request with only the fields the contract names', () => {
    const request = parseAiRequest({
      model: 'apple-foundation', temperature: 0.3, maxTokens: 64, stop: ['\n\n'], toolChoice: { name: 'look' },
      messages: [
        { role: 'system', content: 'Be brief.' },
        { role: 'user', content: [{ type: 'text', text: 'What is this?' }, { type: 'image', mediaType: 'image/png', data: 'iVBORw0KGgo=' }] },
        { role: 'assistant', content: '', toolCalls: [{ id: 'call_1', name: 'look', arguments: '{}' }] },
        { role: 'tool', content: 'a cat', toolCallId: 'call_1' },
      ],
      tools: [{ name: 'look', description: 'Looks', parameters: { type: 'object', properties: { x: { type: 'integer' } } } }],
      responseFormat: { type: 'json', name: 'answer', schema: { type: 'object' } },
    })
    expect(request.messages).toHaveLength(4)
    expect(request.toolChoice).toEqual({ name: 'look' })
    expect(request.responseFormat).toEqual({ type: 'json', name: 'answer', schema: { type: 'object' } })
    const deep = (n: number): unknown => n ? { a: deep(n - 1) } : 1
    for (const bad of [
      null, { model: 'x' }, { model: 'bad model', messages: [{ role: 'user', content: 'hi' }] },
      { model: 'x', messages: [{ role: 'user', content: 'hi' }], extra: 1 },
      { model: 'x', messages: [{ role: 'robot', content: 'hi' }] },
      { model: 'x', messages: [{ role: 'assistant', content: [{ type: 'text', text: 'hi' }] }] },
      { model: 'x', messages: [{ role: 'user', content: [{ type: 'image', mediaType: 'image/svg+xml', data: 'AA==' }] }] },
      { model: 'x', messages: [{ role: 'user', content: [{ type: 'image', mediaType: 'image/png', data: 'not base64!' }] }] },
      { model: 'x', messages: [{ role: 'tool', content: 'x' }] },
      { model: 'x', messages: [{ role: 'user', content: 'x', toolCallId: 'c' }] },
      { model: 'x', messages: [{ role: 'user', content: 'x' }], temperature: 9 },
      { model: 'x', messages: [{ role: 'user', content: 'x' }], seed: 1.5 },
      { model: 'x', messages: [{ role: 'user', content: 'x' }], tools: [{ name: 'a b', parameters: {} }] },
      { model: 'x', messages: [{ role: 'user', content: 'x' }], tools: [{ name: 'ok', parameters: deep(40) }] },
      { model: 'x', messages: [{ role: 'user', content: 'x' }], responseFormat: { type: 'xml' } },
    ]) expect(() => parseAiRequest(bad), JSON.stringify(bad)?.slice(0, 80)).toThrow()
  })

  it('checks the phone\'s models and events field by field', () => {
    expect(parseAiModels([{ ...MODEL, capabilities: ['tools', 'tools'] }])).toEqual([{ ...MODEL, capabilities: ['tools'] }])
    for (const bad of [[{ ...MODEL, id: '' }], [MODEL, MODEL], [{ ...MODEL, capabilities: ['telepathy'] }], [{ ...MODEL, name: 'a\nb' }], [{ ...MODEL, contextSize: 0 }], [{ ...MODEL, extra: 1 }]]) {
      expect(() => parseAiModels(bad)).toThrow()
    }
    expect(parsePhoneMessage({ type: 'delta', id: ID, content: 'Hi\n', toolCalls: [{ index: 0, id: 'call_1', name: 'look', arguments: '{' }] }))
      .toEqual({ type: 'delta', id: ID, content: 'Hi\n', toolCalls: [{ index: 0, id: 'call_1', name: 'look', arguments: '{' }] })
    expect(parsePhoneMessage({ type: 'done', id: ID, finishReason: 'length', usage: { promptTokens: 3, completionTokens: 4 } }))
      .toEqual({ type: 'done', id: ID, finishReason: 'length', usage: { promptTokens: 3, completionTokens: 4 } })
    expect(parsePhoneMessage({ type: 'error', id: ID, status: 400, code: 'context_length_exceeded', message: 'too long' })).toMatchObject({ status: 400 })
    for (const bad of [{ type: 'delta', id: 'x' }, { type: 'delta', id: ID, content: 3 }, { type: 'done', id: ID, finishReason: 'bored', usage: { promptTokens: 1, completionTokens: 1 } },
      { type: 'done', id: ID, finishReason: 'stop', usage: { promptTokens: -1, completionTokens: 1 } }, { type: 'error', id: ID, status: 418, code: 'x', message: 'x' },
      { type: 'error', id: ID, status: 500, code: 'Bad Code', message: 'x' }, { type: 'run', id: ID }, { type: 'started', id: ID, extra: 1 }]) {
      expect(() => parsePhoneMessage(bad), JSON.stringify(bad)).toThrow()
    }
    expect(parseGuestMessage({ type: 'cancel', id: ID })).toEqual({ type: 'cancel', id: ID })
    expect(() => parseGuestMessage({ type: 'cancel', id: 'nope' })).toThrow()
  })
})

/** A stand-in for the guest's caboose-ai relay port: records what the host says. */
async function fakeGuest(token: string) {
  const received: Record<string, unknown>[] = []
  let relay: WebSocket | undefined
  const server = createServer((_request, response) => response.writeHead(404).end())
  const wss = new WebSocketServer({ noServer: true })
  server.on('upgrade', (request: IncomingMessage, socket, head) => {
    if (request.headers.authorization !== `Bearer ${token}` || request.url !== '/relay') { socket.end('HTTP/1.1 401 Unauthorized\r\n\r\n'); return }
    wss.handleUpgrade(request, socket, head, ws => {
      relay = ws
      ws.on('message', data => received.push(JSON.parse(data.toString())))
    })
  })
  server.listen(0, '127.0.0.1')
  await once(server, 'listening')
  close.push(() => new Promise<void>(resolve => { for (const c of wss.clients) c.terminate(); server.close(() => resolve()) }))
  return {
    url: `http://127.0.0.1:${(server.address() as AddressInfo).port}`, received,
    send: (message: unknown) => relay!.send(JSON.stringify(message)),
    connected: () => relay?.readyState === WebSocket.OPEN,
    drop: () => relay?.terminate(),
  }
}

async function host(guestUrl: string) {
  let running = false
  const session = { state: 'running', display: { path: '/v1/display', token: 'display', protocol: 'caboose-display' as const }, computer: { name: 'Caboose', image: 'Debian', memoryMb: 2048, vcpus: 2 } }
  const wake = vi.fn(async () => { running = true; return session })
  const park = vi.fn(async () => { running = false })
  const controller: Controller = { wake, park, activeResources: () => null, hasSavedState: () => false, stats: () => ({}), apps: async () => [], launch: async () => {},
    displayUrl: 'ws://127.0.0.1:1', agentDisplayUrl: 'ws://127.0.0.1:1', ensureAgentSeat: async () => {},
    guest: () => running ? { run: async () => '' } : undefined, aiService: () => running ? { url: guestUrl, token: 'display' } : undefined }
  const settings = new SettingsStore({ name: 'Caboose', memoryMb: 2048, vcpus: 2, idleMs: 60_000, defaultAgent: null }, settingsLimits(), { load: async () => undefined, save: async () => {} })
  const app = createCabooseServer({ token: 'owner', settings, controller })
  app.server.listen(0, '127.0.0.1')
  await once(app.server, 'listening')
  close.push(() => app.shutdown())
  return { base: `http://127.0.0.1:${(app.server.address() as AddressInfo).port}`, wake, app }
}

function phone(base: string) {
  const socket = new WebSocket(`${base.replace('http:', 'ws:')}/v1/ai`, { headers: { authorization: 'Bearer owner' } })
  const received: Record<string, unknown>[] = []
  socket.on('message', data => received.push(JSON.parse(data.toString())))
  close.push(() => { socket.terminate() })
  return { socket, received }
}

describe('/v1/ai', () => {
  it('connects the guest only while the computer runs and a phone offers models, and relays both ways', async () => {
    const guest = await fakeGuest('display')
    const { base, wake, app } = await host(guest.url)
    const iphone = phone(base)
    await once(iphone.socket, 'open')
    iphone.socket.send(JSON.stringify({ type: 'hello', models: [MODEL] }))
    await new Promise(resolve => setTimeout(resolve, 50))
    // A parked computer is not woken for the phone's models.
    expect(wake).not.toHaveBeenCalled()
    expect(guest.connected()).toBe(false)

    await fetch(`${base}/v1/session`, { method: 'POST', headers: { authorization: 'Bearer owner' } })
    await vi.waitFor(() => expect(guest.received).toEqual([{ type: 'phone', models: [MODEL] }]))

    guest.send({ type: 'request', id: ID, request: { model: 'apple-foundation', messages: [{ role: 'user', content: 'hi' }], ignored: undefined } })
    await vi.waitFor(() => expect(iphone.received).toEqual([{ type: 'request', id: ID, request: { model: 'apple-foundation', messages: [{ role: 'user', content: 'hi' }] } }]))
    iphone.socket.send(JSON.stringify({ type: 'started', id: ID }))
    iphone.socket.send(JSON.stringify({ type: 'delta', id: ID, content: 'Hello' }))
    iphone.socket.send(JSON.stringify({ type: 'done', id: ID, finishReason: 'stop', usage: { promptTokens: 5, completionTokens: 1 } }))
    await vi.waitFor(() => expect(guest.received.slice(1)).toEqual([
      { type: 'started', id: ID }, { type: 'delta', id: ID, content: 'Hello' },
      { type: 'done', id: ID, finishReason: 'stop', usage: { promptTokens: 5, completionTokens: 1 } }]))
    // Events for a request that is over, or that this phone was never given, are dropped.
    iphone.socket.send(JSON.stringify({ type: 'delta', id: ID, content: 'late' }))
    iphone.socket.send(JSON.stringify({ type: 'delta', id: 'b'.repeat(32), content: 'stray' }))
    await new Promise(resolve => setTimeout(resolve, 50))
    expect(guest.received).toHaveLength(4)

    // The guest's invalid request is answered by the host, never sent to the phone.
    guest.send({ type: 'request', id: 'c'.repeat(32), request: { model: 'apple-foundation', messages: [] } })
    await vi.waitFor(() => expect(guest.received.at(-1)).toMatchObject({ type: 'error', id: 'c'.repeat(32), status: 400, code: 'invalid_request' }))
    expect(iphone.received).toHaveLength(1)

    await app.computer.park(() => {})
    await vi.waitFor(() => expect(guest.connected()).toBe(false))
  })

  it('fails a request at once when its phone goes away, and tells the guest the phone left', async () => {
    const guest = await fakeGuest('display')
    const { base } = await host(guest.url)
    await fetch(`${base}/v1/session`, { method: 'POST', headers: { authorization: 'Bearer owner' } })
    const iphone = phone(base)
    await once(iphone.socket, 'open')
    iphone.socket.send(JSON.stringify({ type: 'hello', models: [MODEL] }))
    await vi.waitFor(() => expect(guest.connected()).toBe(true))
    guest.send({ type: 'request', id: ID, request: { model: 'apple-foundation', messages: [{ role: 'user', content: 'hi' }] } })
    await vi.waitFor(() => expect(iphone.received).toHaveLength(1))
    iphone.socket.close()
    await vi.waitFor(() => expect(guest.received).toContainEqual(expect.objectContaining({ type: 'error', id: ID, status: 503, code: 'phone_unavailable' })))
    await vi.waitFor(() => expect(guest.received.at(-1)).toEqual({ type: 'phone', models: [] }))
    await vi.waitFor(() => expect(guest.connected()).toBe(false))
  })

  it('cancels the phone\'s work when the guest cancels or its relay drops, and reconnects', async () => {
    const guest = await fakeGuest('display')
    const { base } = await host(guest.url)
    await fetch(`${base}/v1/session`, { method: 'POST', headers: { authorization: 'Bearer owner' } })
    const iphone = phone(base)
    await once(iphone.socket, 'open')
    iphone.socket.send(JSON.stringify({ type: 'hello', models: [MODEL] }))
    await vi.waitFor(() => expect(guest.connected()).toBe(true))
    guest.send({ type: 'request', id: ID, request: { model: 'apple-foundation', messages: [{ role: 'user', content: 'hi' }] } })
    guest.send({ type: 'cancel', id: ID })
    await vi.waitFor(() => expect(iphone.received.at(-1)).toEqual({ type: 'cancel', id: ID }))

    const second = 'd'.repeat(32)
    guest.send({ type: 'request', id: second, request: { model: 'apple-foundation', messages: [{ role: 'user', content: 'again' }] } })
    await vi.waitFor(() => expect(iphone.received.at(-1)).toMatchObject({ type: 'request', id: second }))
    guest.drop()
    await vi.waitFor(() => expect(iphone.received.at(-1)).toEqual({ type: 'cancel', id: second }))
    await vi.waitFor(() => expect(guest.connected()).toBe(true), { timeout: 3000 })
  })

  it('closes a phone that breaks the contract', async () => {
    const guest = await fakeGuest('display')
    const { base } = await host(guest.url)
    const iphone = phone(base)
    await once(iphone.socket, 'open')
    iphone.socket.send(JSON.stringify({ type: 'hello', models: [{ ...MODEL, capabilities: ['root'] }] }))
    const [code] = await once(iphone.socket, 'close') as [number]
    expect(code).toBe(4400)
  })
})
