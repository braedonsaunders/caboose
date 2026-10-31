import { WebSocket, type RawData } from 'ws'

export const GPU_PROTOCOL = 'caboose.gpu.live.v1'
export const GPU_MAX_MESSAGE = 256 * 1024
export const GPU_MAX_PENDING = 1024 * 1024
export const GPU_MAX_PENDING_MESSAGES = 64
export const GPU_CLOSE_TIMEOUT_MS = 1000
/** The phone is pinged this often; one silent this long has left (backgrounded, off the network). */
export const GPU_HEARTBEAT_MS = 1000
export const GPU_HEARTBEAT_TIMEOUT_MS = 3000
/** GPU capabilities a phone may declare; the host forwards only these, never other text. */
export const GPU_FEATURES = ['guest-handles', 'guest-handle-arrays', 'completion-feed', 'ordered-present', 'guest-images'] as const

/** The known features named in a phone's `X-Caboose-GPU-Features` header, sorted. */
export function gpuFeatures(header: string | string[] | undefined): string[] {
  const values = (Array.isArray(header) ? header.join(',') : header ?? '').split(',')
  const known = new Set<string>(GPU_FEATURES)
  return [...new Set(values.map(value => value.trim().toLowerCase()).filter(value => known.has(value)))].sort()
}

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
  features?: readonly string[]
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
      ...(options.features?.length ? { 'x-caboose-gpu-features': options.features.join(',') } : {}),
    },
  })
  return new Promise(resolve => {
    let closed = 0
    let closeTimer: ReturnType<typeof setTimeout> | undefined
    const endpoints = [client, upstream]
    const pending = [0, 0]
    const pendingMessages = [0, 0]
    function stop(): void {
      for (const endpoint of endpoints) if (endpoint.readyState !== WebSocket.CLOSED) endpoint.terminate()
    }
    // A phone that vanishes without closing would leave the guest's GPU clients waiting on
    // it: silence ends the relay, and the broker then ends the executor's streams.
    let heard = Date.now()
    client.on('pong', () => { heard = Date.now() })
    const heartbeat = setInterval(() => {
      if (client.readyState !== WebSocket.OPEN) return
      // While the relay itself holds the phone back, its replies wait unread: not silence.
      if (upstream.readyState !== WebSocket.OPEN || pendingMessages[0]! > 0) { heard = Date.now(); return }
      if (Date.now() - heard > GPU_HEARTBEAT_TIMEOUT_MS) { stop(); return }
      client.ping()
    }, GPU_HEARTBEAT_MS)
    for (const [index, source] of endpoints.entries()) {
      const destination = endpoints[1 - index]!
      source.on('error', stop)
      source.once('close', (code: number) => {
        closed++
        if (closed === 2) {
          if (closeTimer) clearTimeout(closeTimer)
          clearInterval(heartbeat)
          resolve()
          return
        }
        // Preserve the broker's normal close after its native retirement
        // exchange. Abrupt/error paths never manufacture that receipt.
        if (code === 1000 && destination.readyState === WebSocket.OPEN) {
          closeTimer ??= setTimeout(stop, GPU_CLOSE_TIMEOUT_MS)
          destination.resume() // a paused peer must be able to acknowledge Close
          destination.close(1000)
        } else stop()
      })
      source.on('message', (data: RawData, binary: boolean) => {
        if (index === 0) heard = Date.now()
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
