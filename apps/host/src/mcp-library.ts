import { createHash } from 'node:crypto'
import { mkdir, readFile, rename, writeFile } from 'node:fs/promises'
import { dirname } from 'node:path'
import { AgentConflictError, AgentInputError, AgentNotFoundError, type AgentGuest } from './agents.js'
import { fetchSafe, type SafeResponse } from './safe-fetch.js'
import { API, QUALIFIED, type McpServer, type Requester, type SmitheryCatalog } from './smithery.js'

/**
 * A computer's MCP Library: the MCP servers added to it, hosted for it by Smithery Connect in
 * the namespace of the Smithery account its owner connected. Every agent on the computer gets
 * them, in new chats, through one `caboose-library` server (guest/agentd/library-mcp.mjs).
 *
 * The account's API key stays here: it never reaches a client, a log, a URL or the computer.
 * The computer gets a service token Smithery scopes to this computer's connections, valid for
 * a day and replaced well before it ends. Values a server needs (its API keys) go straight to
 * Smithery, which stores them write-only; Caboose keeps no copy.
 */
export const MAX_CONNECTIONS = 20
const DESCRIPTOR = '/home/caboose/.local/state/caboose/mcp-library.json'
const CONNECTION_ID = /^cb-[0-9a-f]{12}-[0-9a-f]{16}$/
const FIELD = /^[A-Za-z0-9_.-]{1,80}$/
const MAX_VALUE = 4096
const TOKEN_MS = 24 * 3600_000
/** A token is replaced once it is this old, so a computer always holds one with hours left. */
const REFRESH_MS = 4 * 3600_000

export type ConnectionStatus =
  | { state: 'connected'; tools: number }
  | { state: 'needs-sign-in'; setupUrl: string }
  | { state: 'needs-setup'; fields: Array<{ key: string; where: 'header' | 'query'; label: string; description: string; required: boolean }>; setupUrl: string | null }
  | { state: 'failed'; message: string }
  | { state: 'checking' }

interface Record_ { id: string; server: string; name: string; iconUrl: string | null; addedAt: string; mcpUrl: string | null }
interface Stored { apiKey: string | null; namespace: string | null; connections: Record_[] }

class SmitheryAuthError extends AgentConflictError {}

/** Messages from Smithery and from servers are never shown: they can carry anything. */
function failure(response: SafeResponse, what: string): Error {
  if (response.status === 401 || response.status === 403) return new SmitheryAuthError('Smithery did not accept the API key. Check it in Smithery and connect again.')
  if (response.status === 404) return new AgentNotFoundError(`${what} was not found in your Smithery account`)
  if (response.status === 429) return new AgentConflictError('Smithery is limiting requests; try again in a minute')
  return new Error(`Smithery could not ${what.toLowerCase()} (${response.status})`)
}
const json = (response: SafeResponse): Record<string, unknown> => {
  try { const value = JSON.parse(response.body.toString('utf8')) as unknown; return value && typeof value === 'object' ? value as Record<string, unknown> : {} } catch { return {} }
}
const smitheryUrl = (value: unknown): string | null => {
  if (typeof value !== 'string' || value.length > 1000) return null
  try { const url = new URL(value); return url.protocol === 'https:' && (url.hostname === 'smithery.ai' || url.hostname.endsWith('.smithery.ai')) ? url.href : null } catch { return null }
}
const label = (value: unknown, max: number) => typeof value === 'string' ? value.replace(/[\x00-\x1f\x7f]/g, ' ').trim().slice(0, max) : ''

/** A connection's id: stable for this host's computer and the server, and unique to both. */
export function connectionId(tag: string, server: string): string {
  const hash = (value: string, length: number) => createHash('sha256').update(value).digest('hex').slice(0, length)
  return `cb-${hash(tag, 12)}-${hash(server, 16)}`
}

/** The Library's status for a connection, from Smithery's, never carrying its text. */
export function readStatus(value: unknown): ConnectionStatus {
  const status = value && typeof value === 'object' ? value as Record<string, unknown> : {}
  if (status.state === 'connected') return { state: 'connected', tools: 0 }
  if (status.state === 'auth_required') {
    const setupUrl = smitheryUrl(status.setupUrl ?? status.authorizationUrl)
    return setupUrl ? { state: 'needs-sign-in', setupUrl } : { state: 'failed', message: 'This server needs a sign-in Caboose could not start.' }
  }
  if (status.state === 'input_required') {
    const http = (status.http && typeof status.http === 'object' ? status.http : {}) as Record<string, unknown>
    const missing = (status.missing && typeof status.missing === 'object' ? status.missing : {}) as Record<string, unknown>
    const fields: Extract<ConnectionStatus, { state: 'needs-setup' }>['fields'] = []
    for (const where of ['header', 'query'] as const) {
      const schema = (http[where === 'header' ? 'headers' : 'query'] ?? {}) as Record<string, unknown>
      const absent = new Set(Array.isArray(missing[where === 'header' ? 'headers' : 'query']) ? (missing[where === 'header' ? 'headers' : 'query'] as unknown[]).filter((k): k is string => typeof k === 'string') : [])
      for (const [key, field] of Object.entries(schema).slice(0, 24)) {
        if (!FIELD.test(key) || !field || typeof field !== 'object') continue
        const f = field as Record<string, unknown>
        fields.push({ key, where, label: label(f.label, 80) || key, description: label(f.description, 400), required: f.required === true || absent.has(key) })
      }
    }
    return { state: 'needs-setup', fields, setupUrl: smitheryUrl(status.setupUrl) }
  }
  if (status.state === 'disconnected') return { state: 'failed', message: 'The server disconnected. Check it again, or remove it.' }
  return { state: 'failed', message: "The server didn't accept the connection. Check its settings, or remove it." }
}

/** The JSON-RPC result for `id` in a Streamable HTTP answer: plain JSON or an SSE stream. */
export function rpcResult(response: SafeResponse, id: number): Record<string, unknown> | null {
  const type = String(response.headers['content-type'] ?? '')
  const messages: unknown[] = []
  const body = response.body.toString('utf8')
  if (type.includes('text/event-stream')) {
    for (const event of body.split(/\r?\n\r?\n/)) {
      const data = event.split(/\r?\n/).filter(line => line.startsWith('data:')).map(line => line.slice(5).trimStart()).join('\n')
      if (data) try { messages.push(JSON.parse(data)) } catch { /* not a message */ }
    }
  } else try { const value = JSON.parse(body) as unknown; messages.push(...(Array.isArray(value) ? value : [value])) } catch { /* not JSON */ }
  const match = messages.find(message => message && typeof message === 'object' && (message as { id?: unknown }).id === id) as { result?: unknown } | undefined
  return match?.result && typeof match.result === 'object' ? match.result as Record<string, unknown> : null
}

export class McpLibrary {
  private state: Stored = { apiKey: null, namespace: null, connections: [] }
  private loaded: Promise<void> | undefined
  private saving: Promise<void> = Promise.resolve()
  private token: { value: string; mintedAt: number; account: number } | null = null
  /** Bumped when the account is connected, replaced or disconnected: a token minted for an
   *  older account is never handed to the computer. */
  private account_ = 0
  /** Bumped on every change: work that started under an older generation does not write back. */
  private generation = 0
  private statuses = new Map<string, ConnectionStatus>()
  private syncedFor: string | null = null
  constructor(private readonly options: {
    file: string
    /** This computer, as Smithery metadata: `<host id>/<computer id>`. */
    tag: string
    catalog: SmitheryCatalog
    guest: () => AgentGuest | undefined
    emit: (event: unknown) => void
    request?: Requester
    now?: () => number
  }) {}
  private get request(): Requester { return this.options.request ?? fetchSafe }
  private get now(): number { return (this.options.now ?? Date.now)() }

  private load(): Promise<void> {
    this.loaded ??= readFile(this.options.file, 'utf8').then(text => {
      const raw = JSON.parse(text) as Partial<Stored>
      this.state = {
        apiKey: typeof raw.apiKey === 'string' && raw.apiKey.length <= 400 ? raw.apiKey : null,
        namespace: typeof raw.namespace === 'string' && /^[a-z0-9][a-z0-9-]{0,63}$/i.test(raw.namespace) ? raw.namespace : null,
        connections: (Array.isArray(raw.connections) ? raw.connections : []).slice(0, MAX_CONNECTIONS).filter(c =>
          c && CONNECTION_ID.test(c.id) && typeof c.server === 'string' && QUALIFIED.test(c.server) && typeof c.name === 'string' && typeof c.addedAt === 'string'),
      }
    }).catch(() => {})
    return this.loaded
  }
  /** Saves run one after another, each writing the state as it is then. */
  private save(): Promise<void> {
    const next = this.saving.then(async () => {
      await mkdir(dirname(this.options.file), { recursive: true })
      await writeFile(this.options.file + '.tmp', JSON.stringify(this.state), { mode: 0o600 })
      await rename(this.options.file + '.tmp', this.options.file)
    })
    this.saving = next.catch(() => {})
    return next
  }
  private changed(id?: string): void { this.generation++; this.options.emit({ type: 'mcp.changed', ...(id ? { id } : {}) }) }

  private async smithery(path: string, init: { method?: 'GET' | 'POST' | 'DELETE' | 'PUT'; body?: unknown; bearer?: string } = {}): Promise<SafeResponse> {
    const bearer = init.bearer ?? this.state.apiKey
    if (!bearer) throw new AgentConflictError('Connect a Smithery account first')
    return this.request(`${API}${path}`, 2 * 1024 * 1024, {
      method: init.method ?? 'GET',
      headers: { authorization: `Bearer ${bearer}`, accept: 'application/json, text/event-stream', ...(init.body !== undefined ? { 'content-type': 'application/json' } : {}) },
      ...(init.body !== undefined ? { body: JSON.stringify(init.body) } : {}),
      timeoutMs: 30_000,
    })
  }

  /** Whether a Smithery account is connected; never the key. */
  async account() {
    await this.load()
    return { connected: !!this.state.apiKey, namespace: this.state.namespace }
  }
  /** Connects a Smithery account by its API key: checked, and its namespace chosen. */
  async connect(apiKey: unknown) {
    if (typeof apiKey !== 'string' || !/^[\x21-\x7e]{8,400}$/.test(apiKey)) throw new AgentInputError('Paste a Smithery API key')
    await this.load()
    const generation = ++this.generation
    const listed = await this.request(`${API}/namespaces`, 1024 * 1024, { headers: { authorization: `Bearer ${apiKey}`, accept: 'application/json' } })
    if (listed.status !== 200) throw failure(listed, 'List namespaces')
    const names = (Array.isArray(json(listed).namespaces) ? json(listed).namespaces as unknown[] : []).flatMap(n => {
      const name = (n as { name?: unknown })?.name
      return typeof name === 'string' && /^[a-z0-9][a-z0-9-]{0,63}$/i.test(name) ? [name] : []
    })
    let namespace = names[0]
    if (!namespace) {
      const created = await this.request(`${API}/namespaces`, 64 * 1024, { method: 'POST', headers: { authorization: `Bearer ${apiKey}`, 'content-type': 'application/json', accept: 'application/json' }, body: '{}' })
      if (created.status !== 201 && created.status !== 200) throw failure(created, 'Create a namespace')
      const name = json(created).name
      if (typeof name !== 'string' || !/^[a-z0-9][a-z0-9-]{0,63}$/i.test(name)) throw new Error('Smithery returned no namespace')
      namespace = name
    }
    if (generation !== this.generation) throw new AgentConflictError('The Library changed while connecting; try again')
    this.state = { apiKey, namespace, connections: this.state.namespace === namespace ? this.state.connections : [] }
    this.token = null
    this.account_++
    await this.save()
    this.changed()
    await this.sync().catch(error => console.error('Cannot update the computer\'s Library:', error instanceof Error ? error.message : error))
    return this.account()
  }
  /** Removes this computer's servers from Smithery, then forgets the account. */
  async disconnect() {
    await this.load()
    for (const connection of [...this.state.connections]) await this.remove(connection.id).catch(() => {})
    this.state = { apiKey: null, namespace: null, connections: [] }
    this.token = null
    this.account_++
    await this.save()
    this.changed()
    await this.sync().catch(() => {})
    return this.account()
  }

  /** The computer's servers and how each is doing, as Smithery last reported it. */
  async connections() {
    await this.load()
    return { account: !!this.state.apiKey, limit: MAX_CONNECTIONS, connections: this.state.connections.map(connection => ({
      id: connection.id, server: connection.server, name: connection.name, iconId: this.options.catalog.iconId(connection.iconUrl), addedAt: connection.addedAt,
      status: this.statuses.get(connection.id) ?? { state: 'checking' as const },
    })) }
  }
  /** Checks every server's status with Smithery, a few at a time. */
  async refresh() {
    await this.load()
    if (!this.state.apiKey) return this.connections()
    const queue = [...this.state.connections]
    await Promise.all(Array.from({ length: 4 }, async () => {
      for (let connection = queue.shift(); connection; connection = queue.shift()) await this.check(connection.id, false).catch(() => {})
    }))
    return this.connections()
  }

  /** Adds a server to this computer. Nothing is added until Smithery has the connection. */
  async add(server: unknown) {
    if (typeof server !== 'string' || !QUALIFIED.test(server)) throw new AgentInputError('Choose a server from the Library')
    await this.load()
    if (!this.state.apiKey || !this.state.namespace) throw new AgentConflictError('Connect a Smithery account first')
    const existing = this.state.connections.find(c => c.server === server)
    if (existing) return this.check(existing.id)
    if (this.state.connections.length >= MAX_CONNECTIONS) throw new AgentConflictError(`A computer holds up to ${MAX_CONNECTIONS} MCP servers. Remove one to add another.`)
    const detail: McpServer = await this.options.catalog.detail(server)
    const id = connectionId(this.options.tag, server)
    const generation = ++this.generation
    await this.remote(id)
    const response = await this.smithery(`/connect/${this.state.namespace}/${id}`, { method: 'PUT', body: { server, name: detail.name.slice(0, 100), metadata: { caboose: this.options.tag } } })
    if (response.status !== 200 && response.status !== 201) throw failure(response, 'Add the server')
    const body = json(response)
    if (generation !== this.generation && this.state.connections.some(c => c.id === id)) throw new AgentConflictError('The Library changed while adding; try again')
    this.state.connections.push({ id, server, name: detail.name, iconUrl: detail.iconUrl, addedAt: new Date(this.now).toISOString(), mcpUrl: typeof body.mcpUrl === 'string' ? body.mcpUrl.slice(0, 1000) : null })
    await this.save()
    this.changed(id)
    return this.settle(id, readStatus(body.status))
  }

  /**
   * Smithery's record of a connection, if it is this computer's: one another computer on the
   * same account made is never changed or removed from here.
   */
  private async remote(id: string): Promise<Record<string, unknown> | null> {
    const response = await this.smithery(`/connect/${this.state.namespace}/${id}`)
    if (response.status === 404) return null
    if (response.status !== 200) throw failure(response, 'Check the server')
    const body = json(response)
    const metadata = body.metadata && typeof body.metadata === 'object' ? body.metadata as Record<string, unknown> : {}
    if (metadata.caboose !== this.options.tag) throw new AgentConflictError('That Smithery connection belongs to another computer')
    return body
  }

  /** Gives a server the settings it asked for. Only the fields it asked for are accepted. */
  async configure(id: string, input: unknown) {
    await this.load()
    const connection = this.find(id)
    const status = this.statuses.get(id)
    if (status?.state !== 'needs-setup') throw new AgentConflictError('This server is not waiting for settings')
    const values = input && typeof input === 'object' ? input as Record<string, unknown> : {}
    const headers: Record<string, string> = {}, query: Record<string, string> = {}
    for (const [key, value] of Object.entries(values)) {
      const field = status.fields.find(f => f.key === key)
      if (!field) throw new AgentInputError(`${key.slice(0, 80)} is not a setting this server asked for`)
      if (typeof value !== 'string' || value.length > MAX_VALUE || /[\x00-\x1f\x7f]/.test(value)) throw new AgentInputError(`${field.label} has an invalid value`)
      if (value) (field.where === 'header' ? headers : query)[key] = value
    }
    for (const field of status.fields) if (field.required && !(field.key in headers || field.key in query)) throw new AgentInputError(`${field.label} is required`)
    let mcpUrl: string | undefined
    if (Object.keys(query).length) {
      if (!connection.mcpUrl) throw new AgentConflictError('Smithery did not say where this server is; remove and add it again')
      const url = new URL(connection.mcpUrl)
      for (const [key, value] of Object.entries(query)) url.searchParams.set(key, value)
      mcpUrl = url.href
    }
    const generation = this.generation
    if (!await this.remote(id)) throw new AgentNotFoundError('Smithery no longer has this server. Remove it, then add it again.')
    const response = await this.smithery(`/connect/${this.state.namespace}/${id}`, { method: 'PUT', body: { ...(mcpUrl ? { mcpUrl } : {}), ...(Object.keys(headers).length ? { headers } : {}) } })
    if (response.status !== 200 && response.status !== 201) throw failure(response, 'Save the settings')
    if (generation !== this.generation && !this.state.connections.some(c => c.id === id)) throw new AgentNotFoundError('The server was removed')
    return this.settle(id, readStatus(json(response).status))
  }

  /** Asks Smithery how the server is; connected means it listed its tools. */
  async check(id: string, announce = true) {
    await this.load()
    this.find(id)
    const body = await this.remote(id)
    if (!body) { this.statuses.set(id, { state: 'failed', message: 'Smithery no longer has this server. Remove it, then add it again.' }); return this.view(id) }
    const connection = this.state.connections.find(c => c.id === id)
    if (connection && typeof body.mcpUrl === 'string') connection.mcpUrl = body.mcpUrl.slice(0, 1000)
    return this.settle(id, readStatus(body.status), announce)
  }
  private async settle(id: string, status: ConnectionStatus, announce = true) {
    const generation = this.generation
    let settled = status
    if (status.state === 'connected') {
      const tools = await this.listTools(id).catch(() => null)
      settled = tools === null ? { state: 'failed', message: 'Smithery connected, but the server did not list its tools. Check it again later.' }
        : tools === 0 ? { state: 'failed', message: 'The server connected but offers no tools.' } : { state: 'connected', tools }
    }
    // A server removed while this ran is not brought back.
    if (!this.state.connections.some(c => c.id === id)) throw new AgentNotFoundError('The server was removed')
    this.statuses.set(id, settled)
    if (announce || generation !== this.generation) this.options.emit({ type: 'mcp.changed', id })
    if (settled.state === 'connected') await this.sync().catch(error => console.error('Cannot update the computer\'s Library:', error instanceof Error ? error.message : error))
    return this.view(id)
  }
  private view(id: string) {
    const connection = this.find(id)
    return { id, server: connection.server, name: connection.name, iconId: this.options.catalog.iconId(connection.iconUrl), addedAt: connection.addedAt, status: this.statuses.get(id) ?? { state: 'checking' as const } }
  }
  /** The tools the server lists, through Smithery's stateless MCP endpoint for one connection. */
  private async listTools(id: string): Promise<number> {
    const token = await this.serviceToken()
    const call = async (rpc: Record<string, unknown>) => this.request(`${API}/connect/${this.state.namespace}/${id}/mcp`, 4 * 1024 * 1024, {
      method: 'POST', body: JSON.stringify({ jsonrpc: '2.0', ...rpc }), timeoutMs: 30_000,
      headers: { authorization: `Bearer ${token}`, 'content-type': 'application/json', accept: 'application/json, text/event-stream' },
    })
    const init = await call({ id: 1, method: 'initialize', params: { protocolVersion: '2025-06-18', capabilities: {}, clientInfo: { name: 'caboose', version: '1' } } })
    if (init.status !== 200 || !rpcResult(init, 1)) throw new Error('initialize failed')
    const tools = await call({ id: 2, method: 'tools/list', params: {} })
    const result = tools.status === 200 ? rpcResult(tools, 2) : null
    if (!result || !Array.isArray(result.tools)) throw new Error('tools/list failed')
    return Math.min(result.tools.length, 10_000)
  }

  /** Removes a server from Smithery and this computer; running chats lose it on their next call. */
  async remove(id: string) {
    await this.load()
    this.find(id)
    if (await this.remote(id)) {
      const response = await this.smithery(`/connect/${this.state.namespace}/${id}`, { method: 'DELETE' })
      if (response.status !== 200 && response.status !== 204 && response.status !== 404) throw failure(response, 'Remove the server')
    }
    this.state.connections = this.state.connections.filter(c => c.id !== id)
    this.statuses.delete(id)
    await this.save()
    this.changed(id)
    await this.sync().catch(error => console.error('Cannot update the computer\'s Library:', error instanceof Error ? error.message : error))
    return { removed: true }
  }
  private find(id: string): Record_ {
    const connection = CONNECTION_ID.test(id) ? this.state.connections.find(c => c.id === id) : undefined
    if (!connection) throw new AgentNotFoundError('That server is not in this computer\'s Library')
    return connection
  }

  /** A day-long token for this computer's connections only, minted with the account's key. */
  private async serviceToken(): Promise<string> {
    const account = this.account_
    if (this.token && this.token.account === account && this.now - this.token.mintedAt < REFRESH_MS) return this.token.value
    const response = await this.smithery('/tokens', { method: 'POST', body: { policy: [{ namespaces: this.state.namespace, resources: 'connections', operations: ['read', 'execute'], metadata: { caboose: this.options.tag }, ttl: TOKEN_MS / 1000 }] } })
    if (response.status !== 200 && response.status !== 201) throw failure(response, 'Create an access token')
    const value = json(response).token
    if (typeof value !== 'string' || !/^[\x21-\x7e]{8,4000}$/.test(value)) throw new Error('Smithery returned no access token')
    // Fail closed: a token for an account that has since changed is thrown away.
    if (account !== this.account_) throw new AgentConflictError('The Smithery account changed')
    this.token = { value, mintedAt: this.now, account }
    return value
  }

  /**
   * Brings the computer's descriptor up to date: the namespace endpoint and a current token
   * while the Library has servers, nothing once it has none. Run before chats start, on wake,
   * after changes, and hourly; the computer must be running.
   */
  async sync(): Promise<boolean> {
    await this.load()
    const guest = this.options.guest()
    if (!guest) return false
    if (!this.state.apiKey || !this.state.namespace || !this.state.connections.length) {
      if (this.syncedFor === '') return false
      await guest.run('/bin/rm', ['-f', '--', DESCRIPTOR], 15_000)
      this.syncedFor = ''
      return false
    }
    const account = this.account_
    let token: string
    try { token = await this.serviceToken() } catch (error) {
      // No token, no access: the computer keeps none it cannot refresh.
      await guest.run('/bin/rm', ['-f', '--', DESCRIPTOR], 15_000).catch(() => {})
      this.syncedFor = null
      throw error
    }
    if (account !== this.account_) return false
    const key = `${this.state.namespace}:${this.token!.mintedAt}`
    if (this.syncedFor === key) return true
    const descriptor = JSON.stringify({ url: `https://mcp.smithery.run/${this.state.namespace}`, token, expiresAt: new Date(this.token!.mintedAt + TOKEN_MS).toISOString() })
    // Written as root and handed to the computer's user, private to it.
    await guest.run('/bin/sh', ['-c', 'umask 077 && mkdir -p "${1%/*}" && printf %s "$2" | base64 -d > "$1.tmp" && chown -R caboose:caboose "${1%/*/*/*}/state" && chmod 600 "$1.tmp" && mv -f "$1.tmp" "$1"',
      'sh', DESCRIPTOR, Buffer.from(descriptor).toString('base64')], 15_000)
    this.syncedFor = key
    return true
  }
  /** Whether new chats should be given the `caboose-library` server. */
  async active(): Promise<boolean> {
    await this.load()
    return !!this.state.apiKey && this.state.connections.length > 0
  }
  /** The guest dropped its state (a restart, a new container): write it again on the next sync. */
  forgetSync(): void { this.syncedFor = null }
}
