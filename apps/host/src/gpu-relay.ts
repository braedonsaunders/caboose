import { WebSocket, type RawData } from 'ws'

export const GPU_PROTOCOL = 'caboose.gpu.live.v1'
export const GPU_MAX_MESSAGE = 256 * 1024
export const GPU_MAX_PENDING = 1024 * 1024
export const GPU_MAX_PENDING_MESSAGES = 64

/** The owner's existing guest service; never a client-supplied destination. */
export function gpuUpstreamURL(displayURL: string): string {
  const url = new URL(displayURL)
  if (!['ws:', 'wss:'].includes(url.protocol) || url.username || url.password) throw new Error('Invalid guest display URL')
  url.pathname = '/gpu'
  url.search = ''
  url.hash = ''
  return url.href
}

function size(data: RawData): number {
  return Array.isArray(data) ? data.reduce((sum, part) => sum + part.byteLength, 0) : data.byteLength
}

/** Opaque live command/reply transport. A flushed send is not GPU completion.
 * Resolves only after both endpoints close, so the executor lease cannot be
 * reused while the previous upstream connection is still alive.
 */
export function relayGPU(client: WebSocket, options: {
  displayURL: string
  displayToken: string
  computer: string
  executor: string
}): Promise<void> {
  if (client.readyState !== WebSocket.OPEN) return Promise.resolve()
  const url = gpuUpstreamURL(options.displayURL)
  client.pause()
  const upstream = new WebSocket(url, GPU_PROTOCOL, {
    maxPayload: GPU_MAX_MESSAGE,
    perMessageDeflate: false,
    handshakeTimeout: 10_000,
    headers: {
      authorization: `Bearer ${options.displayToken}`,
      'x-caboose-gpu-computer': options.computer,
      'x-caboose-gpu-executor': options.executor,
    },
  })
  return new Promise(resolve => {
    let closed = 0
    const endpoints = [client, upstream]
    const pending = [0, 0]
    const pendingMessages = [0, 0]
    function stop(): void {
      for (const endpoint of endpoints) if (endpoint.readyState !== WebSocket.CLOSED) endpoint.terminate()
    }
    for (const [index, source] of endpoints.entries()) {
      const destination = endpoints[1 - index]!
      source.on('error', stop)
      source.once('close', () => {
        closed++
        stop()
        if (closed === 2) resolve()
      })
      source.on('message', (data: RawData, binary: boolean) => {
        const bytes = size(data)
        if (!binary || bytes > GPU_MAX_MESSAGE || destination.readyState !== WebSocket.OPEN ||
            pending[index]! + bytes > GPU_MAX_PENDING ||
            pendingMessages[index]! >= GPU_MAX_PENDING_MESSAGES) { stop(); return }
        source.pause()
        pending[index]! += bytes
        pendingMessages[index]!++
        destination.send(data, { binary: true, compress: false }, error => {
          pending[index]! -= bytes
          pendingMessages[index]!--
          if (error) stop()
          else if (pendingMessages[index] === 0 && source.readyState === WebSocket.OPEN) source.resume()
        })
      })
    }
    upstream.once('open', () => {
      if (upstream.protocol !== GPU_PROTOCOL || client.readyState !== WebSocket.OPEN) stop()
      else client.resume()
    })
  })
}
