import { WebSocket, type RawData } from 'ws'

/**
 * The owner's terminals (docs/architecture.md § Terminal). The guest's caboose-terminal serves
 * one login shell per WebSocket on port 14701; sessions outlive their connection, so a client
 * reattaches with the session id and the output offset it holds. The host relays the stream:
 * binary messages are terminal bytes, text messages are JSON control messages that it checks
 * field by field in both directions.
 */
export const TERMINAL_PORT = 14701
/** Open terminal connections per owner; the guest keeps at most 16 sessions. */
export const MAX_TERMINALS = 8
/** A connection that carries nothing either way for this long is closed (4408). */
export const TERMINAL_IDLE_MS = 15 * 60_000
export const MAX_COLS = 1000
export const MAX_ROWS = 500
const MAX_PAYLOAD = 1024 * 1024
const SESSION_ID = /^[0-9a-f]{32}$/
/** DEC private modes the guest reports for a client to restore after a reset. */
const MODES = new Set(['1', '25', '47', '1000', '1002', '1003', '1004', '1006', '1047', '1049', '2004'])
/** Close codes the guest may end a connection with, passed to the client as they are. */
const GUEST_CLOSE_CODES = new Set([1000, 1013, 4001, 4400, 4404])
export const CLOSE_IDLE = 4408
export const CLOSE_INVALID = 4400

export interface TerminalService { url: string; token: string }
export interface TerminalQuery { cols: number; rows: number; session?: string; offset?: number; wake: boolean }
export interface TerminalSession { id: string; title: string; command: string | null; cwd: string | null; cols: number; rows: number; created: number; attached: boolean }

export class TerminalInputError extends Error {}
/** The guest's terminal service could not be reached or answered outside the contract (502). */
export class TerminalServiceError extends Error {}
export class TerminalGoneError extends Error { constructor() { super('terminal session ended') } }

function integer(value: string | null, name: string, max: number): number {
  if (value === null || !/^[0-9]{1,4}$/.test(value) || Number(value) < 1 || Number(value) > max) throw new TerminalInputError(`${name} must be an integer from 1 to ${max}`)
  return Number(value)
}

/** `/v1/terminal?cols=&rows=[&session=&offset=][&wake=1]`. */
export function parseTerminalQuery(params: URLSearchParams): TerminalQuery {
  for (const name of params.keys()) if (!['cols', 'rows', 'session', 'offset', 'wake'].includes(name)) throw new TerminalInputError(`unknown parameter ${name}`)
  const query: TerminalQuery = { cols: integer(params.get('cols'), 'cols', MAX_COLS), rows: integer(params.get('rows'), 'rows', MAX_ROWS), wake: false }
  const session = params.get('session'), offset = params.get('offset'), wake = params.get('wake')
  if (session !== null) {
    if (!SESSION_ID.test(session)) throw new TerminalInputError('invalid session')
    query.session = session
  }
  if (offset !== null) {
    if (session === null || !/^[0-9]{1,15}$/.test(offset)) throw new TerminalInputError('invalid offset')
    query.offset = Number(offset)
  }
  if (wake !== null) {
    if (wake !== '1') throw new TerminalInputError('wake must be 1')
    query.wake = true
  }
  return query
}

/** The guest's WebSocket for a query. */
export function guestTerminalUrl(service: TerminalService, query: TerminalQuery): string {
  const url = new URL('/', service.url.replace(/^http/, 'ws'))
  url.searchParams.set('cols', String(query.cols))
  url.searchParams.set('rows', String(query.rows))
  if (query.session) url.searchParams.set('session', query.session)
  if (query.offset !== undefined) url.searchParams.set('offset', String(query.offset))
  return url.toString()
}

function object(text: string): Record<string, unknown> | undefined {
  try {
    const value: unknown = JSON.parse(text)
    return value && typeof value === 'object' && !Array.isArray(value) ? value as Record<string, unknown> : undefined
  } catch { return undefined }
}

const isSize = (value: unknown, max: number): value is number => Number.isSafeInteger(value) && (value as number) >= 1 && (value as number) <= max

/** A client's control message, re-encoded: `resize { cols, rows }` or `hangup`. */
export function parseClientControl(text: string): string | undefined {
  const message = object(text)
  if (message?.type === 'resize' && Object.keys(message).length === 3 && isSize(message.cols, MAX_COLS) && isSize(message.rows, MAX_ROWS)) {
    return JSON.stringify({ type: 'resize', cols: message.cols, rows: message.rows })
  }
  if (message?.type === 'hangup' && Object.keys(message).length === 1) return JSON.stringify({ type: 'hangup' })
  return undefined
}

/** The guest's control message, re-encoded with only the fields the contract names. */
export function parseGuestControl(text: string): string | undefined {
  const message = object(text)
  if (message?.type === 'hello') {
    const { session, offset, reset, modes } = message
    if (typeof session !== 'string' || !SESSION_ID.test(session) || !Number.isSafeInteger(offset) || (offset as number) < 0 || typeof reset !== 'boolean') return undefined
    const hello: Record<string, unknown> = { type: 'hello', session, offset, reset }
    if (reset) {
      if (!modes || typeof modes !== 'object' || Array.isArray(modes)) return undefined
      const entries = Object.entries(modes as Record<string, unknown>)
      if (entries.some(([mode, value]) => !MODES.has(mode) || typeof value !== 'boolean')) return undefined
      hello.modes = Object.fromEntries(entries)
    }
    return JSON.stringify(hello)
  }
  if (message?.type === 'exit') {
    const { code, signal } = message
    if (Number.isSafeInteger(code) && (code as number) >= 0 && (code as number) <= 255 && signal === undefined) return JSON.stringify({ type: 'exit', code })
    if (code === null && Number.isSafeInteger(signal) && (signal as number) >= 1 && (signal as number) <= 64) return JSON.stringify({ type: 'exit', code: null, signal })
  }
  return undefined
}

const text = (value: unknown, max: number): value is string => typeof value === 'string' && value.length <= max && !/[\u0000-\u001f\u007f]/.test(value)

/** The guest's session listing, checked field by field. */
export function parseSessions(value: unknown): TerminalSession[] {
  const sessions = (value as { sessions?: unknown } | null)?.sessions
  if (!Array.isArray(sessions) || sessions.length > 64) throw new TerminalServiceError('The terminal service sent an invalid session list')
  return sessions.map(raw => {
    const s = (raw ?? {}) as Record<string, unknown>
    if (typeof s.id !== 'string' || !SESSION_ID.test(s.id) || !text(s.title, 200) || !(s.command === null || text(s.command, 64)) || !(s.cwd === null || text(s.cwd, 4096))
      || !isSize(s.cols, MAX_COLS) || !isSize(s.rows, MAX_ROWS) || !Number.isSafeInteger(s.created) || typeof s.attached !== 'boolean') {
      throw new TerminalServiceError('The terminal service sent an invalid session list')
    }
    return { id: s.id, title: s.title as string, command: s.command as string | null, cwd: s.cwd as string | null, cols: s.cols as number, rows: s.rows as number, created: s.created as number, attached: s.attached }
  })
}

async function guestRequest(service: TerminalService, url: URL): Promise<Response> {
  try {
    return await fetch(url, { headers: { authorization: `Bearer ${service.token}` }, signal: AbortSignal.timeout(10_000) })
  } catch {
    throw new TerminalServiceError('The terminal service is not answering')
  }
}

export async function listTerminalSessions(service: TerminalService): Promise<TerminalSession[]> {
  const response = await guestRequest(service, new URL('/sessions', service.url))
  if (!response.ok) throw new TerminalServiceError(`The terminal service answered ${response.status}`)
  return parseSessions(await response.json().catch(() => null))
}

export async function hangupTerminal(service: TerminalService, id: string): Promise<void> {
  if (!SESSION_ID.test(id)) throw new TerminalGoneError()
  const url = new URL('/hangup', service.url)
  url.searchParams.set('session', id)
  const response = await guestRequest(service, url)
  if (response.status === 404) throw new TerminalGoneError()
  if (!response.ok) throw new TerminalServiceError(`The terminal service answered ${response.status}`)
}

/**
 * Relays one client connection to its own guest connection. Each side is paused until the
 * other has flushed what it sent, so neither buffers output without bound; a slow phone
 * slows the shell instead. Text messages that break the contract close the connection.
 */
export function relayTerminal(client: WebSocket, upstreamUrl: string, token: string, idleMs = TERMINAL_IDLE_MS): void {
  const upstream = new WebSocket(upstreamUrl, { headers: { authorization: `Bearer ${token}` }, maxPayload: MAX_PAYLOAD, handshakeTimeout: 10_000, perMessageDeflate: false })
  client.pause()
  const end = () => { if (upstream.readyState === WebSocket.CONNECTING) upstream.terminate(); else upstream.close(1000) }
  const idle = setTimeout(() => { client.close(CLOSE_IDLE, 'idle'); end() }, idleMs)
  idle.unref()
  upstream.on('open', () => client.resume())
  function forward(source: WebSocket, destination: WebSocket, check: (text: string) => string | undefined, invalid: () => void): void {
    source.on('message', (data: RawData, isBinary: boolean) => {
      if (destination.readyState !== WebSocket.OPEN) return
      idle.refresh()
      let payload: RawData | string = data
      if (!isBinary) {
        const checked = check(data.toString())
        if (checked === undefined) { invalid(); return }
        payload = checked
      }
      source.pause()
      destination.send(payload, { binary: isBinary }, error => {
        if (error) source.terminate()
        else if (source.readyState === WebSocket.OPEN) source.resume()
      })
    })
  }
  forward(client, upstream, parseClientControl, () => client.close(CLOSE_INVALID, 'invalid control message'))
  forward(upstream, client, parseGuestControl, () => { client.close(1011, 'terminal sent an invalid message'); upstream.terminate() })
  upstream.on('unexpected-response', () => { client.close(1011, 'terminal unavailable'); upstream.terminate() })
  upstream.on('error', () => { if (client.readyState !== WebSocket.CLOSED) client.close(1011, 'terminal unavailable'); upstream.terminate() })
  upstream.on('close', (code: number, reason: Buffer) => {
    clearTimeout(idle)
    if (GUEST_CLOSE_CODES.has(code)) client.close(code, reason.toString().slice(0, 120))
    else client.close(1011, 'terminal closed')
  })
  client.once('close', () => { clearTimeout(idle); end() })
}
