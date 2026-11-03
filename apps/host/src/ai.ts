import { WebSocket, type RawData } from 'ws'

/**
 * Caboose AI (docs/ai.md): the phone's language models for programs in the computer. The
 * guest's caboose-ai serves `localhost:11434` inside the computer and takes one relay
 * WebSocket on port 14702; the phone serves its models on `/v1/ai`. The host joins the two
 * while the computer runs and a phone offers models, checking every message field by field in
 * both directions, and fails a request at once when its phone goes away.
 */
export const AI_PORT = 14702
/** Requests running at once per computer; caboose-ai holds the same limit. */
export const MAX_AI_REQUESTS = 16
/** A request with its images; caboose-ai refuses a larger body. */
export const MAX_AI_REQUEST_BYTES = 32 * 1024 * 1024
/** One message from the phone (an answer's pieces are small). */
export const MAX_AI_EVENT_BYTES = 1024 * 1024
/** Texts in one embeddings request. */
export const MAX_EMBED_INPUTS = 256
const RECONNECT_MS = [500, 1000, 2000, 5000, 10_000]

export interface AiService { url: string; token: string }

export interface AiModel {
  id: string
  name: string
  contextSize: number
  capabilities: string[]
  ownedBy?: string
  family?: string
  parameterSize?: string
  quantization?: string
  /** `chat` (the default) or `embedding`. */
  type?: 'chat' | 'embedding'
}

const REQUEST_ID = /^[0-9a-f]{32}$/
const MODEL_ID = /^[A-Za-z0-9][A-Za-z0-9._:/-]{0,127}$/
const TOOL_NAME = /^[A-Za-z0-9_-]{1,64}$/
const ERROR_CODE = /^[a-z][a-z0-9_]{0,63}$/
const CAPABILITIES = new Set(['tools', 'vision', 'json', 'reasoning'])
const IMAGE_TYPES = new Set(['image/png', 'image/jpeg', 'image/gif', 'image/webp', 'image/heic'])
const FINISH = new Set(['stop', 'length', 'tool_calls', 'content_filter'])
const STATUSES = new Set([400, 404, 413, 429, 500, 503])

export class AiInputError extends Error {}

type Json = Record<string, unknown>
const isObject = (value: unknown): value is Json => !!value && typeof value === 'object' && !Array.isArray(value)
const fail = (message: string): never => { throw new AiInputError(message) }

function text(value: unknown, name: string, max: number): string {
  if (typeof value !== 'string' || value.length > max) fail(`${name} must be a string of at most ${max} characters`)
  return value as string
}

/** A one-line label: no control characters. */
function label(value: unknown, name: string, max: number): string {
  const result = text(value, name, max)
  if (/[\u0000-\u001f\u007f]/.test(result)) fail(`${name} has control characters`)
  return result
}

function numberIn(value: unknown, name: string, low: number, high: number, integer = false): number {
  if (typeof value !== 'number' || !Number.isFinite(value) || value < low || value > high || (integer && !Number.isSafeInteger(value))) fail(`${name} must be ${integer ? 'an integer' : 'a number'} from ${low} to ${high}`)
  return value as number
}

function only(value: Json, keys: string[], name: string): void {
  for (const key of Object.keys(value)) if (!keys.includes(key)) fail(`${name} has an unknown field ${key}`)
}

/** A JSON Schema or other plain JSON value, bounded in depth and size, copied. */
function plainJson(value: unknown, name: string, maxBytes = 64 * 1024): unknown {
  const walk = (node: unknown, depth: number): unknown => {
    if (depth > 32) fail(`${name} is nested too deeply`)
    if (node === null || typeof node === 'boolean' || typeof node === 'string') return node
    if (typeof node === 'number') return Number.isFinite(node) ? node : fail(`${name} has a number that is not finite`)
    if (Array.isArray(node)) return node.map(item => walk(item, depth + 1))
    if (isObject(node)) return Object.fromEntries(Object.entries(node).map(([key, item]) => [key, walk(item, depth + 1)]))
    return fail(`${name} is not JSON`)
  }
  const copy = walk(value, 0)
  if (JSON.stringify(copy).length > maxBytes) fail(`${name} is larger than ${maxBytes} bytes`)
  return copy
}

function content(value: unknown, role: string): string | Json[] {
  if (typeof value === 'string') return text(value, 'content', 4_000_000)
  if (!Array.isArray(value) || role !== 'user' || value.length > 64) return fail('content must be a string, or for a user a list of at most 64 parts')
  return value.map(part => {
    if (!isObject(part)) return fail('each part must be an object')
    if (part.type === 'text') { only(part, ['type', 'text'], 'a text part'); return { type: 'text', text: text(part.text, 'text', 4_000_000) } }
    if (part.type === 'image') {
      only(part, ['type', 'mediaType', 'data'], 'an image part')
      if (typeof part.mediaType !== 'string' || !IMAGE_TYPES.has(part.mediaType)) fail('an image must be PNG, JPEG, GIF, WebP or HEIC')
      const data = text(part.data, 'image data', 28_000_000)
      if (!/^[A-Za-z0-9+/]*={0,2}$/.test(data)) fail('image data must be base64')
      return { type: 'image', mediaType: part.mediaType, data }
    }
    return fail('a part must be text or an image')
  })
}

function message(value: unknown): Json {
  if (!isObject(value)) return fail('each message must be an object')
  only(value, ['role', 'content', 'toolCalls', 'toolCallId'], 'a message')
  const role = value.role
  if (role !== 'system' && role !== 'user' && role !== 'assistant' && role !== 'tool') return fail('role must be system, user, assistant or tool')
  const result: Json = { role, content: content(value.content, role) }
  if (value.toolCalls !== undefined) {
    if (role !== 'assistant' || !Array.isArray(value.toolCalls) || value.toolCalls.length > 64) fail('toolCalls is a list of at most 64, on an assistant message')
    result.toolCalls = (value.toolCalls as unknown[]).map(call => {
      if (!isObject(call)) return fail('each tool call must be an object')
      only(call, ['id', 'name', 'arguments'], 'a tool call')
      if (typeof call.name !== 'string' || !TOOL_NAME.test(call.name)) fail('a tool call needs a tool name')
      return { id: label(call.id, 'tool call id', 128), name: call.name, arguments: text(call.arguments, 'tool call arguments', 256 * 1024) }
    })
  }
  if (role === 'tool') result.toolCallId = label(value.toolCallId, 'toolCallId', 128)
  else if (value.toolCallId !== undefined) fail('toolCallId belongs on a tool message')
  return result
}

/** A request from caboose-ai (docs/ai.md § Requests), re-encoded with only the fields it names. */
export function parseAiRequest(value: unknown): Json {
  if (!isObject(value)) return fail('the request must be an object')
  only(value, ['model', 'messages', 'tools', 'toolChoice', 'temperature', 'topP', 'topK', 'seed', 'maxTokens', 'responseFormat', 'stop'], 'the request')
  if (typeof value.model !== 'string' || !MODEL_ID.test(value.model)) fail('model must be a model id')
  if (!Array.isArray(value.messages) || value.messages.length < 1 || value.messages.length > 1024) fail('messages must be a list of 1 to 1024')
  const request: Json = { model: value.model, messages: (value.messages as unknown[]).map(message) }
  if (value.tools !== undefined) {
    if (!Array.isArray(value.tools) || value.tools.length < 1 || value.tools.length > 128) fail('tools must be a list of 1 to 128')
    request.tools = (value.tools as unknown[]).map(tool => {
      if (!isObject(tool)) return fail('each tool must be an object')
      only(tool, ['name', 'description', 'parameters'], 'a tool')
      if (typeof tool.name !== 'string' || !TOOL_NAME.test(tool.name)) fail('a tool needs a name of letters, digits, _ and -')
      if (!isObject(tool.parameters)) fail('tool parameters must be a JSON Schema object')
      return { name: tool.name, description: text(tool.description ?? '', 'tool description', 4000), parameters: plainJson(tool.parameters, 'tool parameters') }
    })
  }
  const choice = value.toolChoice
  if (choice !== undefined) {
    if (choice === 'auto' || choice === 'none' || choice === 'required') request.toolChoice = choice
    else if (isObject(choice) && Object.keys(choice).length === 1 && typeof choice.name === 'string' && TOOL_NAME.test(choice.name)) request.toolChoice = { name: choice.name }
    else fail('toolChoice must be auto, none, required or { name }')
  }
  if (value.temperature !== undefined) request.temperature = numberIn(value.temperature, 'temperature', 0, 2)
  if (value.topP !== undefined) request.topP = numberIn(value.topP, 'topP', 0, 1)
  if (value.topK !== undefined) request.topK = numberIn(value.topK, 'topK', 1, 1000, true)
  if (value.seed !== undefined) request.seed = numberIn(value.seed, 'seed', 0, Number.MAX_SAFE_INTEGER, true)
  if (value.maxTokens !== undefined) request.maxTokens = numberIn(value.maxTokens, 'maxTokens', 1, 1_000_000, true)
  if (value.responseFormat !== undefined) {
    const format = value.responseFormat
    if (!isObject(format) || format.type !== 'json') return fail('responseFormat must be { type: "json", name?, schema? }')
    only(format, ['type', 'name', 'schema'], 'responseFormat')
    request.responseFormat = { type: 'json', ...(format.name !== undefined ? { name: label(format.name, 'responseFormat name', 64) } : {}),
      ...(format.schema !== undefined ? { schema: isObject(format.schema) ? plainJson(format.schema, 'responseFormat schema') : fail('the schema must be an object') } : {}) }
  }
  if (value.stop !== undefined) {
    if (!Array.isArray(value.stop) || value.stop.length > 4) fail('stop must be a list of at most 4')
    request.stop = (value.stop as unknown[]).map(item => text(item, 'stop', 64))
  }
  return request
}

/** The phone's model list (`hello`). */
export function parseAiModels(value: unknown): AiModel[] {
  if (!Array.isArray(value) || value.length > 16) return fail('models must be a list of at most 16')
  const seen = new Set<string>()
  return value.map(raw => {
    if (!isObject(raw)) return fail('each model must be an object')
    only(raw, ['id', 'name', 'contextSize', 'capabilities', 'ownedBy', 'family', 'parameterSize', 'quantization', 'type'], 'a model')
    if (raw.type !== undefined && raw.type !== 'chat' && raw.type !== 'embedding') fail('type must be chat or embedding')
    if (typeof raw.id !== 'string' || !MODEL_ID.test(raw.id) || seen.has(raw.id)) fail('each model needs its own id')
    seen.add(raw.id as string)
    if (!Array.isArray(raw.capabilities) || raw.capabilities.some(c => typeof c !== 'string' || !CAPABILITIES.has(c))) fail('capabilities must be tools, vision, json or reasoning')
    const model: AiModel = { id: raw.id as string, name: label(raw.name, 'model name', 100), contextSize: numberIn(raw.contextSize, 'contextSize', 1, 10_000_000, true), capabilities: [...new Set(raw.capabilities as string[])] }
    for (const key of ['ownedBy', 'family', 'parameterSize', 'quantization'] as const) if (raw[key] !== undefined) model[key] = label(raw[key], key, 64)
    if (raw.type === 'embedding') model.type = 'embedding'
    return model
  })
}

/** One message from the phone, re-encoded: `hello`, or an event for a request it was given. */
export function parsePhoneMessage(value: unknown): Json {
  if (!isObject(value)) return fail('a message must be an object')
  if (value.type === 'hello') { only(value, ['type', 'models'], 'hello'); return { type: 'hello', models: parseAiModels(value.models) } }
  if (typeof value.id !== 'string' || !REQUEST_ID.test(value.id)) return fail('an event needs a request id')
  const id = value.id
  switch (value.type) {
    case 'started':
      only(value, ['type', 'id'], 'started')
      return { type: 'started', id }
    case 'delta': {
      only(value, ['type', 'id', 'content', 'reasoning', 'toolCalls'], 'delta')
      const event: Json = { type: 'delta', id }
      if (value.content !== undefined) event.content = text(value.content, 'content', 64 * 1024)
      if (value.reasoning !== undefined) event.reasoning = text(value.reasoning, 'reasoning', 64 * 1024)
      if (value.toolCalls !== undefined) {
        if (!Array.isArray(value.toolCalls) || value.toolCalls.length > 64) fail('toolCalls must be a list of at most 64')
        event.toolCalls = (value.toolCalls as unknown[]).map(call => {
          if (!isObject(call)) return fail('each tool call must be an object')
          only(call, ['index', 'id', 'name', 'arguments'], 'a tool call')
          const out: Json = { index: numberIn(call.index, 'index', 0, 63, true) }
          if (call.id !== undefined) out.id = label(call.id, 'tool call id', 128)
          if (call.name !== undefined) out.name = typeof call.name === 'string' && TOOL_NAME.test(call.name) ? call.name : fail('a tool call needs a tool name')
          if (call.arguments !== undefined) out.arguments = text(call.arguments, 'arguments', 64 * 1024)
          return out
        })
      }
      return event
    }
    case 'vector': {
      only(value, ['type', 'id', 'index', 'values'], 'vector')
      if (!Array.isArray(value.values) || value.values.length < 1 || value.values.length > 8192) fail('values must be a list of 1 to 8192 numbers')
      return { type: 'vector', id, index: numberIn(value.index, 'index', 0, MAX_EMBED_INPUTS - 1, true),
        values: (value.values as unknown[]).map(v => numberIn(v, 'a value', -1e6, 1e6)) }
    }
    case 'done': {
      only(value, ['type', 'id', 'finishReason', 'usage'], 'done')
      if (typeof value.finishReason !== 'string' || !FINISH.has(value.finishReason)) fail('finishReason must be stop, length, tool_calls or content_filter')
      const usage = isObject(value.usage) ? value.usage : fail('done needs usage')
      only(usage, ['promptTokens', 'completionTokens', 'cachedTokens', 'reasoningTokens'], 'usage')
      const counts: Json = {}
      for (const key of ['promptTokens', 'completionTokens', 'cachedTokens', 'reasoningTokens']) {
        if (usage[key] !== undefined || key === 'promptTokens' || key === 'completionTokens') counts[key] = numberIn(usage[key], key, 0, 100_000_000, true)
      }
      return { type: 'done', id, finishReason: value.finishReason, usage: counts }
    }
    case 'error':
      only(value, ['type', 'id', 'status', 'code', 'message'], 'error')
      if (typeof value.status !== 'number' || !STATUSES.has(value.status)) fail('status must be 400, 404, 413, 429, 500 or 503')
      if (typeof value.code !== 'string' || !ERROR_CODE.test(value.code)) fail('code must be a lowercase identifier')
      return { type: 'error', id, status: value.status, code: value.code, message: text(value.message, 'message', 2000) }
    default:
      return fail('unknown message type')
  }
}

/** An embeddings request from caboose-ai (docs/ai.md § Embeddings). */
export function parseEmbedRequest(value: unknown): Json {
  if (!isObject(value)) return fail('the request must be an object')
  only(value, ['model', 'input'], 'the request')
  if (typeof value.model !== 'string' || !MODEL_ID.test(value.model)) fail('model must be a model id')
  if (!Array.isArray(value.input) || value.input.length < 1 || value.input.length > MAX_EMBED_INPUTS) fail(`input must be a list of 1 to ${MAX_EMBED_INPUTS} strings`)
  return { model: value.model, input: (value.input as unknown[]).map(item => text(item, 'input', 32_000)) }
}

/** One message from caboose-ai: a chat or embeddings request, or a cancellation. */
export function parseGuestMessage(value: unknown): { type: 'request' | 'embed'; id: string; request: Json } | { type: 'cancel'; id: string } {
  if (!isObject(value) || typeof value.id !== 'string' || !REQUEST_ID.test(value.id)) return fail('a message needs a request id')
  if (value.type === 'cancel') { only(value, ['type', 'id'], 'cancel'); return { type: 'cancel', id: value.id } }
  if (value.type === 'request') { only(value, ['type', 'id', 'request'], 'request'); return { type: 'request', id: value.id, request: parseAiRequest(value.request) } }
  if (value.type === 'embed') { only(value, ['type', 'id', 'request'], 'embed'); return { type: 'embed', id: value.id, request: parseEmbedRequest(value.request) } }
  return fail('unknown message type')
}

function json(data: RawData): unknown {
  try { return JSON.parse(data.toString()) } catch { return undefined }
}

function phoneError(id: string, message: string, status = 503, code = 'phone_unavailable') {
  return JSON.stringify({ type: 'error', id, status, code, message })
}

interface Phone { socket: WebSocket; models: AiModel[]; since: number }

/**
 * Joins the phones' `/v1/ai` sockets to the computer's caboose-ai. The relay connection
 * exists while the computer runs and a phone offers models; the newest such phone takes new
 * requests. Nothing here wakes the computer or holds it awake.
 */
export class AiRelay {
  private phones = new Map<WebSocket, Phone>()
  private guest: WebSocket | undefined
  private running = false
  private retry: NodeJS.Timeout | undefined
  private attempts = 0
  /** Request id → the phone running it. */
  private requests = new Map<string, WebSocket>()
  private sentModels = ''
  private sequence = 0

  constructor(private readonly service: () => AiService | undefined) {}

  /** The models the guest is told about: the newest phone's. */
  private active(): Phone | undefined {
    let best: Phone | undefined
    for (const phone of this.phones.values()) if (phone.models.length && (!best || phone.since > best.since)) best = phone
    return best
  }

  get present(): boolean { return !!this.active() }

  /** A phone's `/v1/ai` socket. */
  addPhone(socket: WebSocket): void {
    const phone: Phone = { socket, models: [], since: ++this.sequence }
    this.phones.set(socket, phone)
    socket.on('message', (data, binary) => {
      const parsed = (() => { try { return binary ? undefined : parsePhoneMessage(json(data)) } catch { return undefined } })()
      if (!parsed) { socket.close(4400, 'invalid message'); return }
      if (parsed.type === 'hello') {
        phone.models = parsed.models as AiModel[]
        phone.since = ++this.sequence
        this.sync()
        return
      }
      const id = parsed.id as string
      if (this.requests.get(id) !== socket) return
      if (parsed.type === 'done' || parsed.type === 'error') this.requests.delete(id)
      this.toGuest(JSON.stringify(parsed))
    })
    socket.once('close', () => {
      this.phones.delete(socket)
      for (const [id, owner] of this.requests) {
        if (owner !== socket) continue
        this.requests.delete(id)
        this.toGuest(phoneError(id, 'The phone went away before it finished: Caboose was closed or lost its connection.'))
      }
      this.sync()
    })
  }

  /** The computer started or stopped running. */
  setRunning(running: boolean): void {
    this.running = running
    if (!running) this.attempts = 0
    this.sync()
  }

  close(): void {
    this.running = false
    for (const phone of this.phones.values()) phone.socket.close(1001, 'host stopping')
    this.sync()
  }

  private toGuest(message: string): void {
    if (this.guest?.readyState === WebSocket.OPEN) this.guest.send(message)
  }

  /** Opens or closes the relay connection, and tells caboose-ai the current models. */
  private sync(): void {
    const active = this.active()
    const wanted = this.running && !!active
    if (!wanted) {
      clearTimeout(this.retry)
      this.retry = undefined
      if (this.guest) {
        const guest = this.guest
        this.guest = undefined
        this.toGuestOn(guest, JSON.stringify({ type: 'phone', models: [] }))
        guest.close(1000, 'no phone')
      }
      this.sentModels = ''
      return
    }
    if (!this.guest) { if (!this.retry) this.connect(); return }
    if (this.guest.readyState !== WebSocket.OPEN) return
    const models = JSON.stringify(active!.models)
    if (models !== this.sentModels) {
      this.sentModels = models
      this.guest.send(JSON.stringify({ type: 'phone', models: active!.models }))
    }
  }

  private toGuestOn(guest: WebSocket, message: string): void {
    if (guest.readyState === WebSocket.OPEN) guest.send(message)
  }

  private connect(): void {
    const service = this.service()
    if (!service) { this.schedule(); return }
    const url = new URL('/relay', service.url.replace(/^http/, 'ws'))
    const guest = new WebSocket(url, { headers: { authorization: `Bearer ${service.token}` }, maxPayload: MAX_AI_REQUEST_BYTES + 1024 * 1024, handshakeTimeout: 10_000, perMessageDeflate: false })
    this.guest = guest
    guest.on('open', () => { this.attempts = 0; this.sentModels = ''; this.sync() })
    guest.on('message', (data, binary) => {
      const parsed = (() => { try { return binary ? undefined : parseGuestMessage(json(data)) } catch (error) { return error instanceof AiInputError ? error : undefined } })()
      if (parsed instanceof AiInputError) {
        const id = (json(data) as { id?: unknown } | undefined)?.id
        if (typeof id === 'string' && REQUEST_ID.test(id)) guest.send(phoneError(id, parsed.message, 400, 'invalid_request'))
        return
      }
      if (!parsed) return
      if (parsed.type === 'cancel') {
        const phone = this.requests.get(parsed.id)
        this.requests.delete(parsed.id)
        if (phone?.readyState === WebSocket.OPEN) phone.send(JSON.stringify({ type: 'cancel', id: parsed.id }))
        return
      }
      const phone = this.active()
      if (!phone || phone.socket.readyState !== WebSocket.OPEN) { guest.send(phoneError(parsed.id, 'No phone is offering models.')); return }
      if (this.requests.has(parsed.id)) return
      if (this.requests.size >= MAX_AI_REQUESTS) { guest.send(phoneError(parsed.id, `At most ${MAX_AI_REQUESTS} requests at once.`, 429, 'too_many_requests')); return }
      this.requests.set(parsed.id, phone.socket)
      phone.socket.send(JSON.stringify({ type: parsed.type, id: parsed.id, request: parsed.request }))
    })
    const lost = () => {
      if (this.guest !== guest) return
      this.guest = undefined
      // The program's requests are gone with the connection: the phones stop working on them.
      for (const [id, phone] of this.requests) if (phone.readyState === WebSocket.OPEN) phone.send(JSON.stringify({ type: 'cancel', id }))
      this.requests.clear()
      this.schedule()
    }
    guest.on('error', () => { guest.terminate(); lost() })
    guest.on('unexpected-response', (_request, response) => { response.destroy(); guest.terminate(); lost() })
    guest.on('close', lost)
  }

  private schedule(): void {
    if (this.retry || !this.running || !this.active()) return
    const delay = RECONNECT_MS[Math.min(this.attempts++, RECONNECT_MS.length - 1)]
    this.retry = setTimeout(() => { this.retry = undefined; if (this.running && this.active() && !this.guest) this.connect() }, delay)
    this.retry.unref()
  }
}
