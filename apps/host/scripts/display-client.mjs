// A minimal Caboose Display Protocol client for the real-host checks: it says hello through
// the host's /v1/display relay and reports what the server announced (its features and the
// windows on the display), without decoding any pictures. The wire format is docs/display.md
// § Framing and encoding; guest/display/vectors pins it byte for byte.
import { WebSocket } from 'ws'

const CLIENT_HELLO = 0x81
const SERVER_HELLO = 0x01
const WINDOW_CREATE = 0x02
const WINDOW_UPDATE = 0x03
const WINDOW_DESTROY = 0x04
const BYE = 0x7f

/** A float that encodes as CBOR float64 even when it is a whole number. */
export class Float { constructor(value) { this.value = value } }

function head(major, value) {
  if (value < 24) return Buffer.from([(major << 5) | value])
  if (value < 0x100) return Buffer.from([(major << 5) | 24, value])
  if (value < 0x10000) { const b = Buffer.alloc(3); b[0] = (major << 5) | 25; b.writeUInt16BE(value, 1); return b }
  if (value < 0x100000000) { const b = Buffer.alloc(5); b[0] = (major << 5) | 26; b.writeUInt32BE(value, 1); return b }
  const b = Buffer.alloc(9); b[0] = (major << 5) | 27; b.writeBigUInt64BE(BigInt(value), 1); return b
}

/** Canonical CBOR (RFC 8949 §4.2.1): shortest integers, float64 floats, keys sorted on their encoding. */
export function encode(value) {
  if (value instanceof Float) { const b = Buffer.alloc(9); b[0] = 0xfb; b.writeDoubleBE(value.value, 1); return b }
  if (value === true) return Buffer.from([0xf5])
  if (value === false) return Buffer.from([0xf4])
  if (typeof value === 'number') {
    if (!Number.isInteger(value)) return encode(new Float(value))
    return value >= 0 ? head(0, value) : head(1, -1 - value)
  }
  if (typeof value === 'string') { const text = Buffer.from(value, 'utf8'); return Buffer.concat([head(3, text.length), text]) }
  if (Buffer.isBuffer(value) || value instanceof Uint8Array) return Buffer.concat([head(2, value.length), Buffer.from(value)])
  if (Array.isArray(value)) return Buffer.concat([head(4, value.length), ...value.map(encode)])
  const entries = Object.entries(value).filter(([, v]) => v !== undefined).map(([k, v]) => [encode(k), encode(v)])
  entries.sort(([a], [b]) => a.length - b.length || Buffer.compare(a, b))
  return Buffer.concat([head(5, entries.length), ...entries.flat()])
}

/** Liberal CBOR decoding of one item at `offset`: returns [value, next offset]. */
export function decode(bytes, offset = 0) {
  const initial = bytes[offset], major = initial >> 5, info = initial & 0x1f
  let at = offset + 1, length
  if (major === 7) {
    if (info === 20) return [false, at]
    if (info === 21) return [true, at]
    if (info === 22 || info === 23) return [null, at]
    if (info === 25) return [half(bytes.readUInt16BE(at)), at + 2]
    if (info === 26) return [bytes.readFloatBE(at), at + 4]
    if (info === 27) return [bytes.readDoubleBE(at), at + 8]
    throw new Error(`unsupported CBOR simple value ${info}`)
  }
  if (info < 24) length = info
  else if (info === 24) { length = bytes[at]; at += 1 }
  else if (info === 25) { length = bytes.readUInt16BE(at); at += 2 }
  else if (info === 26) { length = bytes.readUInt32BE(at); at += 4 }
  else if (info === 27) { length = Number(bytes.readBigUInt64BE(at)); at += 8 }
  else throw new Error('indefinite-length CBOR is not used by the protocol')
  switch (major) {
    case 0: return [length, at]
    case 1: return [-1 - length, at]
    case 2: return [bytes.subarray(at, at + length), at + length]
    case 3: return [bytes.toString('utf8', at, at + length), at + length]
    case 4: {
      const items = []
      for (let i = 0; i < length; i++) { const [item, next] = decode(bytes, at); items.push(item); at = next }
      return [items, at]
    }
    case 5: {
      const map = {}
      for (let i = 0; i < length; i++) {
        const [key, afterKey] = decode(bytes, at)
        const [item, next] = decode(bytes, afterKey)
        map[key] = item; at = next
      }
      return [map, at]
    }
    case 6: return decode(bytes, at) // tags are read through
  }
  throw new Error(`unknown CBOR major type ${major}`)
}

function half(bits) {
  const exponent = (bits >> 10) & 0x1f, fraction = bits & 0x3ff, sign = bits & 0x8000 ? -1 : 1
  if (exponent === 0) return sign * 2 ** -14 * (fraction / 1024)
  if (exponent === 31) return fraction ? NaN : sign * Infinity
  return sign * 2 ** (exponent - 15) * (1 + fraction / 1024)
}

/** One protocol message: type, u32 little-endian length, one CBOR map. */
export function frame(type, fields) {
  const payload = encode(fields)
  const header = Buffer.alloc(5)
  header[0] = type; header.writeUInt32LE(payload.length, 1)
  return Buffer.concat([header, payload])
}

/** Splits a byte stream into messages; keeps an incomplete tail for the next chunk. */
export function reader() {
  let pending = Buffer.alloc(0)
  return chunk => {
    pending = Buffer.concat([pending, chunk])
    const messages = []
    while (pending.length >= 5) {
      const length = pending.readUInt32LE(1)
      if (pending.length < 5 + length) break
      const type = pending[0], payload = pending.subarray(5, 5 + length)
      pending = pending.subarray(5 + length)
      try { messages.push({ type, fields: decode(payload)[0] }) } catch { /* a payload that does not decode is dropped */ }
    }
    return messages
  }
}

/**
 * Connects to `url` (the host's /v1/display, `?seat=agent` for the agent seat), says hello
 * with the per-wake `token`, and collects windows for `ms` after the server's hello.
 * Resolves `{ features, encoders, windows: Map<id, { title, app_id, kind }> }`.
 */
export function peek(url, { token, headers = {}, ms = 2_000, timeoutMs = 60_000 }) {
  return new Promise((resolve, reject) => {
    const ws = new WebSocket(url, 'binary', { headers, maxPayload: 16 * 1024 * 1024 })
    const read = reader()
    const windows = new Map()
    let hello
    const fail = error => { clearTimeout(timer); ws.terminate(); reject(error) }
    const timer = setTimeout(() => fail(new Error(`no hello from ${url} within ${timeoutMs} ms`)), timeoutMs)
    ws.on('open', () => ws.send(frame(CLIENT_HELLO, {
      version: 0, token, decoders: ['hevc', 'h264'],
      displays: [{ id: 1, width: 1920, height: 1080, scale: new Float(1), refresh_hz: new Float(60), hdr: false }],
    })))
    ws.on('message', data => {
      for (const { type, fields } of read(Buffer.from(data))) {
        if (type === BYE) return fail(new Error(`the display said bye: ${fields.reason}`))
        if (type === SERVER_HELLO && !hello) {
          hello = fields
          setTimeout(() => { clearTimeout(timer); ws.close(); resolve({ features: hello.features ?? [], encoders: hello.encoders ?? [], windows }) }, ms)
        }
        if (type === WINDOW_CREATE) windows.set(fields.id, { title: fields.title ?? '', app_id: fields.app_id ?? '', kind: fields.kind })
        if (type === WINDOW_UPDATE && windows.has(fields.id)) Object.assign(windows.get(fields.id), Object.fromEntries(['title', 'app_id'].filter(k => k in fields).map(k => [k, fields[k]])))
        if (type === WINDOW_DESTROY) windows.delete(fields.id)
      }
    })
    ws.on('error', fail)
    ws.on('close', () => { if (!hello) fail(new Error(`${url} closed before hello`)) })
  })
}

/** `peek` through the host: the session's display path, authorized as the owner. */
export function peekSession(base, owner, session, { seat = 'owner', ms } = {}) {
  const target = new URL(session.display.path, base)
  if (seat === 'agent') target.searchParams.set('seat', 'agent')
  target.protocol = target.protocol === 'https:' ? 'wss:' : 'ws:'
  return peek(target, { token: session.display.token, headers: { authorization: `Bearer ${owner}` }, ...(ms ? { ms } : {}) })
}

/**
 * Launches each `[app id, title]` through the host and waits up to `timeoutMs` for a new
 * window whose title contains the title. Each look connects as a client, which ends any
 * other client's session on that display (`bye { reason: "replaced" }`).
 */
export async function expectNewWindows(base, owner, session, request, wanted, timeoutMs = 60_000) {
  const titles = async () => new Map([...(await peekSession(base, owner, session)).windows].map(([id, w]) => [id, w.title]))
  const before = await titles()
  for (const [id] of wanted) await request(`/v1/apps/${encodeURIComponent(id)}/launch`, 'POST')
  const deadline = Date.now() + timeoutMs
  let missing = wanted.map(([, title]) => title)
  while (Date.now() < deadline && missing.length) {
    const after = await titles()
    missing = missing.filter(title => ![...after].some(([id, value]) => !before.has(id) && value.includes(title)))
    if (missing.length) await new Promise(resolve => setTimeout(resolve, 1000))
  }
  if (missing.length) throw new Error(`No new window for: ${missing.join(', ')}; close existing windows and retry`)
}
