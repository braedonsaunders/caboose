import { once } from 'node:events'
import { createServer, type IncomingMessage } from 'node:http'
import type { AddressInfo } from 'node:net'
import { WebSocket, WebSocketServer } from 'ws'
import { afterEach, describe, expect, it, vi } from 'vitest'
import { createCabooseServer, type Controller } from './server.js'
import { SettingsStore, settingsLimits } from './settings.js'
import { CLOSE_IDLE, MAX_TERMINALS, guestTerminalUrl, parseClientControl, parseGuestControl, parseSessions, parseTerminalQuery, relayTerminal } from './terminal.js'

const close: Array<() => Promise<void>> = []
afterEach(async () => { for (const f of close.splice(0).reverse()) await f() })

const SESSION = 'a'.repeat(32)

describe('terminal protocol', () => {
  it('accepts a size, a session to reattach with its offset, and a wake', () => {
    expect(parseTerminalQuery(new URLSearchParams('cols=80&rows=24'))).toEqual({ cols: 80, rows: 24, wake: false })
    expect(parseTerminalQuery(new URLSearchParams(`cols=1000&rows=500&session=${SESSION}&offset=99&wake=1`))).toEqual({ cols: 1000, rows: 500, session: SESSION, offset: 99, wake: true })
    for (const query of ['', 'cols=80', 'cols=0&rows=24', 'cols=1001&rows=24', 'cols=80&rows=501', 'cols=8.5&rows=24', 'cols=80&rows=24&session=abc',
      'cols=80&rows=24&offset=3', `cols=80&rows=24&session=${SESSION}&offset=-1`, 'cols=80&rows=24&wake=true', 'cols=80&rows=24&shell=zsh']) {
      expect(() => parseTerminalQuery(new URLSearchParams(query)), query).toThrow()
    }
    expect(guestTerminalUrl({ url: 'http://192.0.2.2:14701', token: 't' }, { cols: 80, rows: 24, session: SESSION, offset: 5, wake: true }))
      .toBe(`ws://192.0.2.2:14701/?cols=80&rows=24&session=${SESSION}&offset=5`)
  })

  it('passes only the control messages the contract names, re-encoded', () => {
    expect(parseClientControl('{"type":"resize","cols":120,"rows":40}')).toBe('{"type":"resize","cols":120,"rows":40}')
    expect(parseClientControl('{"type":"hangup"}')).toBe('{"type":"hangup"}')
    for (const text of ['x', '[]', 'null', '{"type":"resize","cols":0,"rows":4}', '{"type":"resize","cols":"80","rows":4}', '{"type":"resize","cols":80,"rows":24,"x":1}',
      '{"type":"hangup","now":true}', '{"type":"exec","command":"ls"}']) {
      expect(parseClientControl(text), text).toBeUndefined()
    }
    expect(parseGuestControl(`{"type":"hello","session":"${SESSION}","offset":12,"reset":false,"extra":1}`)).toBe(`{"type":"hello","session":"${SESSION}","offset":12,"reset":false}`)
    expect(parseGuestControl(`{"type":"hello","session":"${SESSION}","offset":0,"reset":true,"modes":{"1049":true,"25":false}}`))
      .toBe(`{"type":"hello","session":"${SESSION}","offset":0,"reset":true,"modes":{"25":false,"1049":true}}`)
    expect(parseGuestControl('{"type":"exit","code":3}')).toBe('{"type":"exit","code":3}')
    expect(parseGuestControl('{"type":"exit","code":null,"signal":1}')).toBe('{"type":"exit","code":null,"signal":1}')
    for (const text of [`{"type":"hello","session":"x","offset":0,"reset":false}`, `{"type":"hello","session":"${SESSION}","offset":-1,"reset":false}`,
      `{"type":"hello","session":"${SESSION}","offset":0,"reset":true}`, `{"type":"hello","session":"${SESSION}","offset":0,"reset":true,"modes":{"9":true}}`,
      '{"type":"exit","code":256}', '{"type":"exit","code":null}', '{"type":"exit","code":1,"signal":9}', '{"type":"notice","text":"hi"}']) {
      expect(parseGuestControl(text), text).toBeUndefined()
    }
  })

  it('checks the session list field by field', () => {
    const session = { id: SESSION, title: 'caboose@caboose: ~', command: 'vim', cwd: '/home/caboose/src', cols: 80, rows: 24, created: 1, attached: false }
    expect(parseSessions({ sessions: [{ ...session, extra: true }] })).toEqual([session])
    expect(parseSessions({ sessions: [{ ...session, command: null, cwd: null }] })).toEqual([{ ...session, command: null, cwd: null }])
    for (const bad of [null, {}, { sessions: [{ ...session, id: 'x' }] }, { sessions: [{ ...session, title: 'a\u001b]0;b' }] }, { sessions: [{ ...session, cols: 0 }] }]) {
      expect(() => parseSessions(bad)).toThrow()
    }
  })
})

/** A stand-in for the guest's caboose-terminal: echoes input, answers resize, ends on hangup. */
async function fakeGuest(token: string) {
  const seen: { url: string; messages: string[] }[] = []
  let sessions: unknown = { sessions: [] }
  const server = createServer((request, response) => {
    if (request.headers.authorization !== `Bearer ${token}`) { response.writeHead(401).end(); return }
    const url = new URL(request.url ?? '/', 'http://guest')
    if (url.pathname === '/sessions') { response.writeHead(200, { 'content-type': 'application/json' }).end(JSON.stringify(sessions)); return }
    if (url.pathname === '/hangup') { response.writeHead(url.searchParams.get('session') === SESSION ? 200 : 404).end('{}'); return }
    response.writeHead(404).end()
  })
  const wss = new WebSocketServer({ noServer: true })
  server.on('upgrade', (request: IncomingMessage, socket, head) => {
    if (request.headers.authorization !== `Bearer ${token}`) { socket.end('HTTP/1.1 401 Unauthorized\r\n\r\n'); return }
    wss.handleUpgrade(request, socket, head, ws => {
      const record = { url: request.url ?? '', messages: [] as string[] }
      seen.push(record)
      const url = new URL(record.url, 'http://guest')
      const session = url.searchParams.get('session')
      if (session === 'b'.repeat(32)) { ws.close(4404, 'session ended'); return }
      if (session === 'c'.repeat(32)) { ws.send('{"type":"hello","session":"oops"}'); return }
      ws.send(JSON.stringify({ type: 'hello', session: SESSION, offset: 0, reset: true, modes: {}, debug: 'dropped' }))
      ws.on('message', (data, binary) => {
        if (binary) { ws.send(data, { binary: true }); return }
        record.messages.push(data.toString())
        const message = JSON.parse(data.toString())
        if (message.type === 'resize') ws.send(Buffer.from(`${message.rows} ${message.cols}\r\n`))
        if (message.type === 'hangup') { ws.send('{"type":"exit","code":null,"signal":1}'); ws.close(1000, 'exited') }
      })
    })
  })
  server.listen(0, '127.0.0.1')
  await once(server, 'listening')
  close.push(() => new Promise(resolve => { for (const c of wss.clients) c.terminate(); server.close(() => resolve()) }))
  return { url: `http://127.0.0.1:${(server.address() as AddressInfo).port}`, seen, setSessions: (value: unknown) => { sessions = value } }
}

async function host(guestUrl: string, idleMs = 50) {
  const wake = vi.fn(async () => ({ state: 'running', display: { path: '/v1/display', token: 'display', protocol: 'caboose-display' as const }, computer: { name: 'Caboose', image: 'Debian', memoryMb: 2048, vcpus: 2 } }))
  const park = vi.fn(async () => {})
  let running = false
  wake.mockImplementation(async () => { running = true; return { state: 'running', display: { path: '/v1/display', token: 'display', protocol: 'caboose-display' as const }, computer: { name: 'Caboose', image: 'Debian', memoryMb: 2048, vcpus: 2 } } })
  park.mockImplementation(async () => { running = false })
  const controller: Controller = { wake, park, activeResources: () => null, hasSavedState: () => false, stats: () => ({}), apps: async () => [], launch: async () => {},
    displayUrl: 'ws://127.0.0.1:1', agentDisplayUrl: 'ws://127.0.0.1:1', ensureAgentSeat: async () => {},
    guest: () => running ? { run: async () => '' } : undefined, terminalService: () => ({ url: guestUrl, token: 'display' }) }
  const settings = new SettingsStore({ name: 'Caboose', memoryMb: 2048, vcpus: 2, idleMs, defaultAgent: null }, settingsLimits(), { load: async () => undefined, save: async () => {} })
  const app = createCabooseServer({ token: 'owner', settings, controller })
  app.server.listen(0, '127.0.0.1')
  await once(app.server, 'listening')
  close.push(() => app.shutdown())
  const base = `http://127.0.0.1:${(app.server.address() as AddressInfo).port}`
  return { base, wake, park, app }
}

function open(base: string, query: string, token = 'owner') {
  return new WebSocket(`${base.replace('http:', 'ws:')}/v1/terminal?${query}`, { headers: { authorization: `Bearer ${token}` } })
}

/** The status of a refused upgrade. */
async function refusal(socket: WebSocket): Promise<number> {
  socket.on('error', () => {})
  const [, response] = await once(socket, 'unexpected-response') as [unknown, IncomingMessage]
  response.destroy()
  return response.statusCode ?? 0
}

function messages(socket: WebSocket) {
  const received: { data: string; binary: boolean }[] = []
  socket.on('message', (data, binary) => received.push({ data: data.toString(), binary }))
  return received
}

describe('/v1/terminal', () => {
  it('answers 409 while parked unless asked to wake, then relays a session while holding a lease', async () => {
    const guest = await fakeGuest('display')
    const { base, wake, park, app } = await host(guest.url)
    expect(await refusal(open(base, 'cols=80&rows=24', 'wrong'))).toBe(401)
    expect(await refusal(open(base, 'cols=0&rows=24'))).toBe(400)
    expect(await refusal(open(base, 'cols=80&rows=24'))).toBe(409)
    expect(wake).not.toHaveBeenCalled()

    const client = open(base, 'cols=80&rows=24&wake=1')
    const received = messages(client)
    await once(client, 'open')
    expect(wake).toHaveBeenCalledTimes(1)
    await vi.waitFor(() => expect(received[0]).toEqual({ data: `{"type":"hello","session":"${SESSION}","offset":0,"reset":true,"modes":{}}`, binary: false }))
    expect(guest.seen[0]?.url).toBe('/?cols=80&rows=24')

    client.send(Buffer.from('echo hi\r'))
    client.send(JSON.stringify({ type: 'resize', cols: 100, rows: 30 }))
    await vi.waitFor(() => expect(received.slice(1)).toEqual([{ data: 'echo hi\r', binary: true }, { data: '30 100\r\n', binary: true }]))
    expect(guest.seen[0]?.messages).toEqual(['{"type":"resize","cols":100,"rows":30}'])

    const status = await (await fetch(`${base}/v1/computer`, { headers: { authorization: 'Bearer owner' } })).json() as { clients: unknown }
    expect(status.clients).toEqual({ display: 0, control: 0, terminal: 1 })
    await new Promise(resolve => setTimeout(resolve, 120))
    expect(park).not.toHaveBeenCalled()

    client.send('{"type":"hangup"}')
    const [code] = await once(client, 'close') as [number]
    expect(code).toBe(1000)
    expect(received.at(-1)).toEqual({ data: '{"type":"exit","code":null,"signal":1}', binary: false })
    await vi.waitFor(() => expect(park).toHaveBeenCalledTimes(1))
    expect(app.computer.state).toBe('parked')
  })

  it('closes a client that breaks the contract, and passes the guest\'s endings on', async () => {
    const guest = await fakeGuest('display')
    const { base } = await host(guest.url, 60_000)
    await fetch(`${base}/v1/session`, { method: 'POST', headers: { authorization: 'Bearer owner' } })

    const rude = open(base, 'cols=80&rows=24')
    await once(rude, 'open')
    rude.send('{"type":"exec","command":"rm -rf ~"}')
    const [rudeCode] = await once(rude, 'close') as [number]
    expect(rudeCode).toBe(4400)
    expect(guest.seen.at(-1)?.messages).toEqual([])

    const ended = open(base, `cols=80&rows=24&session=${'b'.repeat(32)}&offset=4`)
    const [endedCode, reason] = await once(ended, 'close') as [number, Buffer]
    expect([endedCode, reason.toString()]).toEqual([4404, 'session ended'])
    expect(guest.seen.at(-1)?.url).toBe(`/?cols=80&rows=24&session=${'b'.repeat(32)}&offset=4`)

    const lying = open(base, `cols=80&rows=24&session=${'c'.repeat(32)}`)
    const lies = messages(lying)
    const [lyingCode] = await once(lying, 'close') as [number]
    expect(lyingCode).toBe(1011)
    expect(lies).toEqual([])
  })

  it('caps open terminals per owner', async () => {
    const guest = await fakeGuest('display')
    const { base } = await host(guest.url, 60_000)
    await fetch(`${base}/v1/session`, { method: 'POST', headers: { authorization: 'Bearer owner' } })
    const clients = Array.from({ length: MAX_TERMINALS }, () => open(base, 'cols=80&rows=24'))
    await Promise.all(clients.map(client => once(client, 'open')))
    expect(await refusal(open(base, 'cols=80&rows=24'))).toBe(429)
    clients[0]!.close()
    await once(clients[0]!, 'close')
    await vi.waitFor(async () => {
      const next = open(base, 'cols=80&rows=24')
      await once(next, 'open')
      next.close()
    })
    for (const client of clients) client.close()
  })

  it('carries a large burst intact and in order', async () => {
    const guest = await fakeGuest('display')
    const { base } = await host(guest.url, 60_000)
    await fetch(`${base}/v1/session`, { method: 'POST', headers: { authorization: 'Bearer owner' } })
    const client = open(base, 'cols=80&rows=24')
    const chunks: Buffer[] = []
    client.on('message', (data, binary) => { if (binary) chunks.push(data as Buffer) })
    await once(client, 'open')
    const sent: Buffer[] = []
    for (let i = 0; i < 200; i++) {
      const chunk = Buffer.alloc(64 * 1024, i % 251)
      sent.push(chunk)
      client.send(chunk)
    }
    await vi.waitFor(() => expect(chunks.reduce((n, c) => n + c.length, 0)).toBe(200 * 64 * 1024), { timeout: 10_000 })
    expect(Buffer.concat(chunks).equals(Buffer.concat(sent))).toBe(true)
    client.close()
  })

  it('lists and hangs up sessions through the guest, checking what it says', async () => {
    const guest = await fakeGuest('display')
    const { base } = await host(guest.url, 60_000)
    const auth = { authorization: 'Bearer owner' }
    expect((await fetch(`${base}/v1/terminal/sessions`, { headers: auth })).status).toBe(409)
    await fetch(`${base}/v1/session`, { method: 'POST', headers: auth })
    const session = { id: SESSION, title: 'caboose@caboose: ~', command: 'bash', cwd: '/home/caboose', cols: 80, rows: 24, created: 1, attached: true }
    guest.setSessions({ sessions: [session] })
    expect(await (await fetch(`${base}/v1/terminal/sessions`, { headers: auth })).json()).toEqual({ sessions: [session] })
    guest.setSessions({ sessions: [{ ...session, cwd: 42 }] })
    expect((await fetch(`${base}/v1/terminal/sessions`, { headers: auth })).status).toBe(502)
    expect((await fetch(`${base}/v1/terminal/sessions/${SESSION}`, { method: 'DELETE', headers: auth })).status).toBe(200)
    expect((await fetch(`${base}/v1/terminal/sessions/${'d'.repeat(32)}`, { method: 'DELETE', headers: auth })).status).toBe(404)
    expect((await fetch(`${base}/v1/terminal/sessions/nope`, { method: 'DELETE', headers: auth })).status).toBe(404)
  })
})

it('closes a connection that carries nothing either way', async () => {
  const guest = await fakeGuest('display')
  const wss = new WebSocketServer({ port: 0 })
  await once(wss, 'listening')
  close.push(() => new Promise(resolve => wss.close(() => resolve())))
  const accepted = once(wss, 'connection')
  const client = new WebSocket(`ws://127.0.0.1:${(wss.address() as AddressInfo).port}`)
  const [server] = await accepted as [WebSocket]
  relayTerminal(server, guestTerminalUrl({ url: guest.url, token: 'display' }, { cols: 80, rows: 24, wake: false }), 'display', 150)
  const [code, reason] = await once(client, 'close') as [number, Buffer]
  expect([code, reason.toString()]).toEqual([CLOSE_IDLE, 'idle'])
})
