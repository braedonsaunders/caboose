import { WebSocket, type RawData } from 'ws'

export const GPU_PROTOCOL = 'caboose.gpu.live.v1'
export const GPU_MAX_MESSAGE = 256 * 1024
/** Bounds on what one direction may queue. Pausing a WebSocket cannot retract messages it
 * already parsed, so a burst of small guest messages while the phone is busy (decoding a
 * pipeline compile, say) arrives after the pause: the bounds hold such a burst, and only a
 * peer that keeps sending far past them is ended. */
export const GPU_MAX_PENDING = 8 * 1024 * 1024
export const GPU_MAX_PENDING_MESSAGES = 2048
export const GPU_CLOSE_TIMEOUT_MS = 1000
/** The phone is pinged this often; one silent this long has left (backgrounded, off the network). */
export const GPU_HEARTBEAT_MS = 1000
export const GPU_HEARTBEAT_TIMEOUT_MS = 3000
/** GPU capabilities a phone may declare; the host forwards only these, never other text. */
export const GPU_FEATURES = ['guest-handles', 'guest-handle-arrays', 'completion-feed', 'ordered-present', 'guest-images', 'guest-query-pools', 'shader-cache'] as const

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
    let stopped = false
    // Every relay that ends early says why, in the host's log.
    function stop(reason: string): void {
      if (!stopped) {
        stopped = true
        console.warn(`gpu relay ${options.executor}: stopped: ${reason}`)
      }
      for (const endpoint of endpoints) if (endpoint.readyState !== WebSocket.CLOSED) endpoint.terminate()
    }
    // A phone that vanishes without closing would leave the guest's GPU clients waiting on
    // it: silence ends the relay, and the broker then ends the executor's streams.
    let heard = Date.now()
    // The phone pings on its own while delivery to a busy decoder holds back its reading.
    client.on('pong', () => { heard = Date.now() })
    client.on('ping', () => { heard = Date.now() })
    const heartbeat = setInterval(() => {
      if (client.readyState !== WebSocket.OPEN) return
      // While the relay itself holds the phone back, its replies wait unread: not silence.
      if (upstream.readyState !== WebSocket.OPEN || pendingMessages[0]! > 0) { heard = Date.now(); return }
      if (Date.now() - heard > GPU_HEARTBEAT_TIMEOUT_MS) { stop(`phone silent for ${Date.now() - heard} ms`); return }
      client.ping()
    }, GPU_HEARTBEAT_MS)
    for (const [index, source] of endpoints.entries()) {
      const destination = endpoints[1 - index]!
      const name = index === 0 ? 'phone' : 'guest'
      source.on('error', (error: Error) => stop(`${name} socket error: ${error.message}`))
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
          closeTimer ??= setTimeout(() => stop(`${index === 0 ? 'guest' : 'phone'} did not acknowledge close`), GPU_CLOSE_TIMEOUT_MS)
          destination.resume() // a paused peer must be able to acknowledge Close
          destination.close(1000)
        } else stop(`${name} closed (code ${code ?? 'none'})`)
      })
      source.on('message', (data: RawData, binary: boolean) => {
        if (index === 0) heard = Date.now()
        const bytes = size(data)
        const refusal = !binary ? 'a text message' : bytes > GPU_MAX_MESSAGE ? `a ${bytes}-byte message` :
          destination.readyState !== WebSocket.OPEN ? 'its peer is not open' :
          pending[index]! + bytes > GPU_MAX_PENDING || pendingMessages[index]! >= GPU_MAX_PENDING_MESSAGES
            ? `queue full (${pendingMessages[index]} messages, ${pending[index]} bytes)` : undefined
        if (refusal) { stop(`${name} sent ${refusal}`); return }
        source.pause()
        pending[index]! += bytes
        pendingMessages[index]!++
        destination.send(data, { binary: true, compress: false }, error => {
          pending[index]! -= bytes
          pendingMessages[index]!--
          if (error) stop(`send to ${index === 0 ? 'guest' : 'phone'} failed: ${error.message}`)
          else if (pendingMessages[index] === 0 && source.readyState === WebSocket.OPEN) source.resume()
        })
      })
    }
    upstream.once('open', () => {
      if (upstream.protocol !== GPU_PROTOCOL || client.readyState !== WebSocket.OPEN) stop('the guest refused the protocol or the phone left')
      else client.resume()
    })
  })
}
