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
/** With `executor-resume` (docs/gpu-live.md, "Resuming an executor"), how long a relay whose
 * phone left keeps the guest side for it to come back: after a lost transport, and after a
 * phone that closed as suspended (close code 4001). */
export const GPU_RESUME_HOLD_MS = 30_000
export const GPU_SUSPEND_HOLD_MS = 30 * 60_000
export const GPU_SUSPENDED_CLOSE = 4001
/** The close code that tells the phone its executor ended with the guest side (a broker that
 * ended without its retirement exchange, as at a display restart): there is nothing to resume,
 * so it frees the executor at once (docs/gpu-live.md, "Resuming an executor"). */
export const GPU_EXECUTOR_ENDED_CLOSE = 4410
/** GPU capabilities a phone may declare; the host forwards only these, never other text. */
export const GPU_FEATURES = ['guest-handles', 'guest-handle-arrays', 'completion-feed', 'ordered-present', 'guest-images', 'guest-query-pools', 'shader-cache', 'executor-resume', 'zstd-stream', 'upload-cache', 'guest-buffer-views', 'batched-descriptor-sets', 'guest-set-ids', 'silent-success'] as const

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

/** Envelope kinds that suspend and resume a phone's executor (docs/gpu-live.md,
 * "Suspending an executor"), as the phone sends them in whole CGLV envelopes. */
const EXECUTOR_SUSPEND = 42
const EXECUTOR_RESUME = 45

/** Whether a phone message suspends (true) or resumes (false) its executor, or neither
 * (undefined), from the kinds of the whole envelopes it holds. */
export function suspension(data: RawData): boolean | undefined {
  const bytes = Array.isArray(data) ? Buffer.concat(data) : Buffer.isBuffer(data) ? data : Buffer.from(data as ArrayBuffer)
  let found: boolean | undefined
  for (let at = 0; at + 64 <= bytes.length;) {
    if (bytes.toString('latin1', at, at + 4) !== 'CGLV') return found
    const kind = bytes.readUInt16LE(at + 6)
    if (kind === EXECUTOR_SUSPEND) found = true
    else if (kind === EXECUTOR_RESUME) found = false
    at += 64 + bytes.readUInt32LE(at + 8)
  }
  return found
}

function size(data: RawData): number {
  return Array.isArray(data) ? data.reduce((sum, part) => sum + part.byteLength, 0) : data.byteLength
}

/** A running relay. `attach` splices a resuming phone onto it (`executor-resume`). */
export interface GPURelay {
  /** Settles once the guest side and the current phone side are both closed. */
  done: Promise<void>
  /** Takes `client` as the phone side, ending any previous one; false once the relay has ended. */
  attach(client: WebSocket): boolean
  /** Ends both sides abruptly (the computer parks, the phone is revoked). */
  end(): void
  /** Whether it has ended or is ending: a phone can no longer be attached. */
  readonly ended: boolean
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
  return startGPURelay(client, options).done
}

/** The relay, which with `resumable` parks instead of ending when its phone side is lost:
 * it drops what the guest side sends (the broker's retained envelopes are the only replay)
 * and keeps it open for GPU_RESUME_HOLD_MS, or GPU_SUSPEND_HOLD_MS after a phone that closed as
 * suspended, for `attach`. The guest side never sees the phone leave unless the hold expires;
 * then it is ended abruptly, as a lost executor. */
export function startGPURelay(first: WebSocket, options: {
  displayURL: string
  displayToken: string
  computer: string
  executor: string
  features?: readonly string[]
  resumable?: boolean
}): GPURelay {
  if (first.readyState !== WebSocket.OPEN) return { done: Promise.resolve(), attach: () => false, end: () => {}, ended: true }
  const url = gpuUpstreamURL(options.displayURL)
  first.pause()
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
  let attachPhone: (client: WebSocket) => boolean = () => false
  let endRelay: () => void = () => {}
  let isEnded: () => boolean = () => false
  const done = new Promise<void>(resolve => {
    let phone: WebSocket | undefined = first
    // Each phone side gets a generation; callbacks of an earlier one are ignored.
    let generation = 0
    let upstreamOpen = false
    let closeTimer: ReturnType<typeof setTimeout> | undefined
    let holdTimer: ReturnType<typeof setTimeout> | undefined
    // Bytes and messages queued towards [guest, phone].
    const pending = [0, 0]
    const pendingMessages = [0, 0]
    let stopped = false
    let settled = false
    function settle(): void {
      if (settled || upstream.readyState !== WebSocket.CLOSED || (phone && phone.readyState !== WebSocket.CLOSED)) return
      settled = true
      if (closeTimer) clearTimeout(closeTimer)
      if (holdTimer) clearTimeout(holdTimer)
      clearInterval(heartbeat)
      resolve()
    }
    // Every relay that ends early says why, in the host's log.
    function stop(reason: string): void {
      if (!stopped) {
        stopped = true
        console.warn(`gpu relay ${options.executor}: stopped: ${reason}`)
      }
      if (holdTimer) { clearTimeout(holdTimer); holdTimer = undefined }
      for (const endpoint of [phone, upstream]) if (endpoint && endpoint.readyState !== WebSocket.CLOSED) endpoint.terminate()
      settle()
    }
    // A phone that suspended its executor and then went silent (iOS suspended the app
    // before its 4001 close) is held as long as one that closed as suspended.
    let suspended = false
    // The phone side is lost: a resumable relay keeps the guest side for a while.
    function lose(reason: string, hold = suspended ? GPU_SUSPEND_HOLD_MS : GPU_RESUME_HOLD_MS): void {
      // After a stop, the phone side's own close is the last thing the relay waits for.
      if (stopped) { settle(); return }
      // A relay already closing has nothing to hold the guest side for.
      if (!options.resumable || closeTimer) { stop(reason); return }
      const lost = phone
      phone = undefined
      generation++
      pending[1] = 0
      pendingMessages[1] = 0
      if (lost && lost.readyState !== WebSocket.CLOSED) lost.terminate()
      // The guest side is still read, so a broker that ends (a display restart) ends the
      // relay; what it sends meanwhile is dropped and sent again after a resume.
      if (upstreamOpen) upstream.resume()
      if (holdTimer) clearTimeout(holdTimer)
      console.warn(`gpu relay ${options.executor}: parked for ${hold} ms: ${reason}`)
      holdTimer = setTimeout(() => stop(`no phone resumed within ${hold} ms`), hold)
      settle()
    }
    // A phone that vanishes without closing would leave the guest's GPU clients waiting on
    // it: silence loses the phone side.
    let heard = Date.now()
    const heartbeat = setInterval(() => {
      if (!phone || phone.readyState !== WebSocket.OPEN) return
      // While the relay itself holds the phone back, its replies wait unread: not silence.
      if (!upstreamOpen || pendingMessages[0]! > 0) { heard = Date.now(); return }
      if (Date.now() - heard > GPU_HEARTBEAT_TIMEOUT_MS) { lose(`phone silent for ${Date.now() - heard} ms`); return }
      phone.ping()
    }, GPU_HEARTBEAT_MS)
    // Guest to phone.
    upstream.on('error', (error: Error) => stop(`guest socket error: ${error.message}`))
    upstream.once('close', (code: number) => {
      // Preserve the broker's normal close after its native retirement exchange. Abrupt
      // and error paths never manufacture that receipt.
      if (code === 1000 && phone?.readyState === WebSocket.OPEN && !stopped) {
        const destination = phone
        closeTimer ??= setTimeout(() => stop('phone did not acknowledge close'), GPU_CLOSE_TIMEOUT_MS)
        destination.resume() // a paused peer must be able to acknowledge Close
        destination.close(1000)
        settle()
      } else if (phone?.readyState === WebSocket.OPEN && !stopped) {
        // No receipt to forward, but the phone learns its executor ended now, rather than
        // from a refused resume after it reconnects.
        console.warn(`gpu relay ${options.executor}: guest closed (code ${code ?? 'none'}); ending the phone's executor`)
        const destination = phone
        closeTimer ??= setTimeout(() => stop('phone did not acknowledge close'), GPU_CLOSE_TIMEOUT_MS)
        destination.resume()
        destination.close(GPU_EXECUTOR_ENDED_CLOSE, 'executor ended')
        settle()
      } else stop(`guest closed (code ${code ?? 'none'})`)
    })
    upstream.on('message', (data: RawData, binary: boolean) => {
      // Sent while no phone is attached: the broker sends it again after a resume.
      if (!phone) return
      forward(upstream, phone, 1, data, binary, generation)
    })
    function forward(source: WebSocket, destination: WebSocket, index: 0 | 1, data: RawData, binary: boolean, at: number): void {
      const name = index === 0 ? 'phone' : 'guest'
      const bytes = size(data)
      const refusal = !binary ? 'a text message' : bytes > GPU_MAX_MESSAGE ? `a ${bytes}-byte message` :
        destination.readyState !== WebSocket.OPEN ? 'its peer is not open' :
        pending[index]! + bytes > GPU_MAX_PENDING || pendingMessages[index]! >= GPU_MAX_PENDING_MESSAGES
          ? `queue full (${pendingMessages[index]} messages, ${pending[index]} bytes)` : undefined
      if (refusal) {
        if (index === 1 && destination.readyState !== WebSocket.OPEN) lose(`phone side not open for a guest message`)
        else stop(`${name} sent ${refusal}`)
        return
      }
      source.pause()
      pending[index]! += bytes
      pendingMessages[index]!++
      destination.send(data, { binary: true, compress: false }, error => {
        if (index === 1 && at !== generation) return
        pending[index]! -= bytes
        pendingMessages[index]!--
        if (error) {
          if (index === 1) lose(`send to phone failed: ${error.message}`)
          else stop(`send to guest failed: ${error.message}`)
        } else if (pendingMessages[index] === 0 && source.readyState === WebSocket.OPEN && (index === 1 || phone === source)) source.resume()
      })
    }
    function wire(client: WebSocket): void {
      const at = generation
      client.on('pong', () => { if (at === generation) heard = Date.now() })
      client.on('ping', () => { if (at === generation) heard = Date.now() })
      client.on('error', (error: Error) => { if (at === generation) lose(`phone socket error: ${error.message}`) })
      client.once('close', (code: number) => {
        if (at !== generation) { settle(); return }
        if (code === 1000 && upstream.readyState === WebSocket.OPEN && !stopped) {
          closeTimer ??= setTimeout(() => stop('guest did not acknowledge close'), GPU_CLOSE_TIMEOUT_MS)
          upstream.resume()
          upstream.close(1000)
          settle()
        } else if (code === GPU_SUSPENDED_CLOSE && options.resumable) lose('phone suspended', GPU_SUSPEND_HOLD_MS)
        else lose(`phone closed (code ${code ?? 'none'})`)
      })
      client.on('message', (data: RawData, binary: boolean) => {
        if (at !== generation) return
        heard = Date.now()
        if (options.resumable) suspended = suspension(data) ?? suspended
        forward(client, upstream, 0, data, binary, at)
      })
    }
    wire(first)
    endRelay = () => stop('ended by the host')
    isEnded = () => stopped || settled || closeTimer !== undefined
    attachPhone = client => {
      if (stopped || settled || closeTimer) return false
      const previous = phone
      generation++
      pending[1] = 0
      pendingMessages[1] = 0
      if (previous && previous.readyState !== WebSocket.CLOSED) previous.terminate()
      if (holdTimer) { clearTimeout(holdTimer); holdTimer = undefined }
      phone = client
      heard = Date.now()
      wire(client)
      console.warn(`gpu relay ${options.executor}: phone resumed`)
      if (upstreamOpen) upstream.resume()
      else client.pause()
      return true
    }
    upstream.once('open', () => {
      if (upstream.protocol !== GPU_PROTOCOL || !phone || phone.readyState !== WebSocket.OPEN) { stop('the guest refused the protocol or the phone left'); return }
      upstreamOpen = true
      phone.resume()
    })
  })
  return { done, attach: client => attachPhone(client), end: () => endRelay(), get ended() { return isEnded() } }
}
