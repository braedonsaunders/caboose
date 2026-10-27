import { createServer, type IncomingMessage, type ServerResponse } from 'node:http'
import { WebSocket, WebSocketServer } from 'ws'
import { authenticate } from './auth.js'
import { ComputerLifecycle, type ComputerDriver } from './lifecycle.js'

export interface App { id: string; name: string; icon: string; categories: string[]; exec: string }
export interface Session { state: string; display: { path: string; token: string; protocol: 'xpra-ws' }; computer: { name: string; image: string; memoryMb: number; vcpus: number } }
export interface Controller extends ComputerDriver<Session> {
  stats(): unknown
  apps(): Promise<App[]>
  launch(id: string): Promise<void>
  displayUrl: string
}

export function createCabooseServer(options: { token: string; idleMs: number; controller: Controller }) {
  const { controller, token } = options
  const computer = new ComputerLifecycle(controller, options.idleMs)
  const sockets = new Set<WebSocket>()
  const controls = new Set<WebSocket>()
  const wss = new WebSocketServer({ noServer: true, maxPayload: 16 * 1024 * 1024, handleProtocols: protocols => protocols.has('binary') ? 'binary' : false })
  computer.subscribe(state => {
    const message = JSON.stringify({ type: 'computer.state', state })
    for (const socket of controls) if (socket.readyState === WebSocket.OPEN) socket.send(message)
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
      return json(response, 404, { error: 'not found' })
    })().catch(error => {
      console.error('Caboose request failed:', error)
      if (!response.headersSent) json(response, 500, { error: 'computer operation failed' })
      else response.destroy()
    })
  })
  server.on('upgrade', (request, socket, head) => {
    const path = new URL(request.url ?? '/', 'http://localhost').pathname
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
        const upstream = new WebSocket(controller.displayUrl, 'binary', { maxPayload: 16 * 1024 * 1024, handshakeTimeout: 10_000 })
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
