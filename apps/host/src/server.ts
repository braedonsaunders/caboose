import { createServer, type IncomingMessage, type ServerResponse } from 'node:http'
import { WebSocket, WebSocketServer } from 'ws'
import { authenticate } from './auth.js'
import { AgentInputError, AgentTasks, AgentUnavailableError, type AgentGuest } from './agents.js'
import { ComputerLifecycle, type ComputerDriver } from './lifecycle.js'

export interface App { id: string; name: string; icon: string; categories: string[]; exec: string }
export interface Session { state: string; display: { path: string; token: string; protocol: 'xpra-ws' }; computer: { name: string; image: string; memoryMb: number; vcpus: number } }
export interface Controller extends ComputerDriver<Session> {
  stats(): unknown
  apps(): Promise<App[]>
  launch(id: string): Promise<void>
  displayUrl: string
  /** The agent seat's Xpra (display :101). */
  agentDisplayUrl: string
  ensureAgentSeat(): Promise<void>
  /** Root command runner in the running computer, or undefined while parked. */
  guest(): AgentGuest | undefined
}

async function readJson(request: IncomingMessage, limit = 64 * 1024): Promise<Record<string, unknown>> {
  const chunks: Buffer[] = []
  let size = 0
  for await (const chunk of request) {
    size += chunk.length
    if (size > limit) throw new AgentInputError('request body too large')
    chunks.push(chunk as Buffer)
  }
  if (!size) return {}
  try {
    const value = JSON.parse(Buffer.concat(chunks).toString('utf8'))
    if (value && typeof value === 'object' && !Array.isArray(value)) return value as Record<string, unknown>
  } catch {}
  throw new AgentInputError('request body must be a JSON object')
}

export function createCabooseServer(options: { token: string; idleMs: number; controller: Controller }) {
  const { controller, token } = options
  const computer = new ComputerLifecycle(controller, options.idleMs)
  const sockets = new Set<WebSocket>()
  const controls = new Set<WebSocket>()
  const wss = new WebSocketServer({ noServer: true, maxPayload: 16 * 1024 * 1024, handleProtocols: protocols => protocols.has('binary') ? 'binary' : false })
  function broadcast(event: unknown): void {
    const message = JSON.stringify(event)
    for (const socket of controls) if (socket.readyState === WebSocket.OPEN) socket.send(message)
  }
  const agents = new AgentTasks(() => controller.guest(), broadcast, () => computer.acquire(), 1000, () => controller.ensureAgentSeat())
  computer.subscribe(state => {
    broadcast({ type: 'computer.state', state })
    if (state === 'running') agents.resume()
    else agents.pause()
  })
  function json(response: ServerResponse, status: number, body: unknown): void {
    response.writeHead(status, { 'content-type': 'application/json', 'cache-control': 'no-store' })
    response.end(JSON.stringify(body))
  }
  function authorized(request: IncomingMessage): boolean { return authenticate(request.headers.authorization, token) }
  const server = createServer((request, response) => {
    void (async () => {
      if (!authorized(request)) return json(response, 401, { error: 'unauthorized' })
      const path = new URL(request.url ?? '/', 'http://localhost').pathname
      if (request.method === 'GET' && path === '/v1/health') return json(response, 200, controller.stats())
      if (request.method === 'POST' && path === '/v1/session') return json(response, 200, await computer.wake())
      if (request.method === 'POST' && path === '/v1/session/park') {
        for (const socket of sockets) socket.terminate()
        await computer.park()
        return json(response, 200, { state: computer.state })
      }
      if (request.method === 'GET' && path === '/v1/apps') {
        if (computer.state !== 'running') return json(response, 409, { error: 'computer is not running' })
        const release = computer.acquire()
        try { return json(response, 200, await controller.apps()) } finally { release() }
      }
      const match = /^\/v1\/apps\/([^/]+)\/launch$/.exec(path)
      if (request.method === 'POST' && match?.[1]) {
        if (computer.state !== 'running') return json(response, 409, { error: 'computer is not running' })
        const release = computer.acquire()
        try {
          await controller.launch(decodeURIComponent(match[1]))
          return json(response, 200, { launched: true })
        } finally { release() }
      }
      if (path === '/v1/agent/tasks' && request.method === 'GET') return json(response, 200, agents.list())
      if (path === '/v1/agent/tasks' && request.method === 'POST') {
        if (computer.state !== 'running') return json(response, 409, { error: 'computer is not running' })
        const task = await agents.start(await readJson(request))
        return json(response, 200, { id: task.id })
      }
      const cancel = /^\/v1\/agent\/tasks\/([0-9a-f-]{36})\/cancel$/.exec(path)
      if (request.method === 'POST' && cancel?.[1]) {
        return json(response, 200, { cancelled: await agents.cancel(cancel[1]) })
      }
      const hold = /^\/v1\/agent\/tasks\/([0-9a-f-]{36})\/(pause|resume)$/.exec(path)
      if (request.method === 'POST' && hold?.[1]) {
        const id = hold[1]
        return json(response, 200, hold[2] === 'pause' ? { paused: await agents.pauseTask(id) } : { resumed: await agents.resumeTask(id) })
      }
      return json(response, 404, { error: 'not found' })
    })().catch(error => {
      if (error instanceof AgentInputError) return json(response, 400, { error: error.message })
      if (error instanceof AgentUnavailableError) return json(response, 409, { error: error.message })
      console.error('Caboose request failed:', error)
      if (!response.headersSent) json(response, 500, { error: 'computer operation failed' })
      else response.destroy()
    })
  })
  /** Byte relay between a client and a guest Xpra, with backpressure in both directions. */
  function relay(client: WebSocket, upstreamUrl: string): void {
    const upstream = new WebSocket(upstreamUrl, 'binary', { maxPayload: 16 * 1024 * 1024, handshakeTimeout: 10_000 })
    // Pause the sender until the destination flushes, bounding queued data.
    client.pause()
    upstream.on('open', () => client.resume())
    function forward(source: WebSocket, destination: WebSocket): void {
      source.on('message', (data, isBinary) => {
        if (!isBinary || destination.readyState !== WebSocket.OPEN) { source.close(1003, 'binary required'); return }
        source.pause()
        destination.send(data, { binary: true }, error => {
          if (error) source.terminate()
          else if (source.readyState === WebSocket.OPEN) source.resume()
        })
      })
    }
    forward(client, upstream); forward(upstream, client)
    upstream.on('error', () => { client.terminate(); upstream.terminate() })
    upstream.on('close', () => client.close())
    client.once('close', () => upstream.terminate())
  }

  server.on('upgrade', (request, socket, head) => {
    const url = new URL(request.url ?? '/', 'http://localhost')
    const path = url.pathname
    if (!authorized(request)) { socket.end('HTTP/1.1 401 Unauthorized\r\nConnection: close\r\n\r\n'); return }
    if (path !== '/v1/display' && path !== '/v1/control') { socket.end('HTTP/1.1 404 Not Found\r\nConnection: close\r\n\r\n'); return }
    if (computer.state !== 'running') { socket.end('HTTP/1.1 409 Conflict\r\nConnection: close\r\n\r\n'); return }
    const offered = request.headers['sec-websocket-protocol']?.split(',').map(value => value.trim()) ?? []
    if (path === '/v1/display' && !offered.includes('binary')) { socket.end('HTTP/1.1 400 Bad Request\r\nConnection: close\r\n\r\n'); return }
    const release = computer.acquire()
    socket.once('close', release)
    try {
      wss.handleUpgrade(request, socket, head, client => {
        sockets.add(client)
        client.on('error', () => client.terminate())
        client.once('close', () => { sockets.delete(client); controls.delete(client); release() })
        if (path === '/v1/control') {
          controls.add(client)
          client.send(JSON.stringify({ type: 'computer.state', state: computer.state }))
          return
        }
        if (url.searchParams.get('seat') === 'agent') {
          // The agent seat starts on demand; hold the client until it is up.
          client.pause()
          controller.ensureAgentSeat().then(
            () => { if (client.readyState === WebSocket.OPEN) relay(client, controller.agentDisplayUrl) },
            () => client.close(1011, 'agent seat unavailable'))
          return
        }
        relay(client, controller.displayUrl)
      })
    } catch { release(); socket.destroy() }
  })
  async function shutdown(): Promise<void> {
    for (const socket of sockets) socket.terminate()
    await computer.park()
    await new Promise<void>((resolve, reject) => server.close(error => error ? reject(error) : resolve()))
  }
  return { server, computer, shutdown }
}
