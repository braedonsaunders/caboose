import type { CatalogOperation, CatalogResponse } from './catalog.js'
import { fsQuery, joinPath, numberedName, type FileItem } from './files.js'
import type { ComponentsUpgrade, HealthStatus, HostInfo } from './host.js'

export type ComputerState = 'parked' | 'waking' | 'running' | 'parking' | 'restarting' | 'error'

export interface LimitRange {
  min: number
  max: number
}

export interface ComputerLimits {
  memoryMb: LimitRange
  vcpus: LimitRange
  idleMs: LimitRange
}

export interface ComputerSettings {
  name: string
  memoryMb: number
  vcpus: number
  idleMs: number
}

export interface ComputerResources {
  memoryMb: number
  vcpus: number
}

export interface ComputerStatus {
  state: ComputerState
  settings: ComputerSettings
  limits?: ComputerLimits
  activeResources: ComputerResources | null
  restartRequired: boolean
  clients: {
    display: number
    control: number
  }
  capabilities: {
    restart: boolean
    /** APNs is configured. Absent from hosts older than push notifications. */
    push?: boolean
  }
  /** The guest-components upgrade on the last wake, from hosts that run one. */
  upgrade?: ComponentsUpgrade | null
  lastError: string | null
}

/** A computer as the host lists it (`GET /v1/computers`): its id and when it was made, with its status. */
export interface ComputerSummary extends ComputerStatus {
  id: string
  /** Null for an owner's computer made before the host recorded it. */
  createdAt: string | null
  /** The tenant the computer belongs to; null on a host that has not been set up. */
  tenantId: string | null
  /** The person whose computer it is, who uses it from their phone. */
  person: string | null
}

export interface ComputersResponse {
  computers: ComputerSummary[]
  /** False for a host that serves only the owner's computer. */
  canCreate: boolean
  limits: { computers: number; running: number | null }
}

/** The owner's computer: the one the owner token's own routes serve, and the one that cannot be deleted. */
export const OWNER_COMPUTER = 'owner'

export interface NewComputer {
  name: string
  memoryMb: number
  vcpus: number
  idleMs: number
  /** Required on a host with accounts. */
  tenantId?: string
  person?: string | null
}

/** Limits on what a tenant's computers are given between them; null is no limit. */
export interface Quotas { memoryMb: number | null; vcpus: number | null; diskGb: number | null }

export interface TenantUsage { computers: number; memoryMb: number; vcpus: number; diskBytes: number | null }

export interface Tenant {
  id: string
  name: string
  quotas: Quotas
  createdAt: string
  usage?: TenantUsage
}

/** Who the console is signed in as: the owner token, or an administrator's account. */
export interface Me {
  kind: 'owner' | 'admin'
  user: { id: string; name: string; email: string } | null
  /** The owner token and the operator's account see the host and every tenant. */
  operator: boolean
  tenants: Tenant[]
}

export interface Administrator { userId: string; name: string; email: string; operator: boolean; joinedAt: string | null }
export interface PendingInvite { id: string; email: string; createdAt: string; expiresAt: string }
export interface InviteDetails { tenantName: string; email: string; expiresAt: string; accountExists: boolean }

export interface SetupInput { name: string; email: string; password: string; tenantName: string; code?: string }

/** The link an invited administrator opens; the token is in the address only, never stored. */
export function buildInviteLink(origin: string, token: string): string {
  return `${origin.replace(/\/+$/, '')}/invite?token=${encodeURIComponent(token)}`
}

/** A phone signed in to a computer with its own token. The host never shows the token again. */
export interface PhoneSignIn {
  id: string
  name: string
  createdAt: string
  lastUsedAt: string | null
}

export interface PairingCode {
  code: string
  expiresAt: string
}

export type PushKind = 'approval' | 'task' | 'desktop'

/** A phone registered for push notifications; `id` is a fingerprint of its token, never the token. */
export interface PushDevice {
  id: string
  environment: 'sandbox' | 'production'
  kinds: PushKind[]
}

export interface SessionInfo {
  state: string
  display: {
    path: string
    token: string
    protocol: 'caboose-display'
  }
  computer: {
    name: string
    image: string
    memoryMb: number
    vcpus: number
  }
}

export const DEFAULT_LIMITS: ComputerLimits = {
  memoryMb: { min: 512, max: 65_536 },
  vcpus: { min: 1, max: 32 },
  idleMs: { min: 60_000, max: 86_400_000 },
}

export const SESSION_TOKEN_KEY = 'caboose.ownerToken'

const CONTROL_CHAR_PATTERN = /[\u0000-\u001F\u007F]/

export function effectiveLimits(status?: Pick<ComputerStatus, 'limits'> | null): ComputerLimits {
  return status?.limits ?? DEFAULT_LIMITS
}

export function readSessionToken(storage?: Pick<Storage, 'getItem'>): string {
  try {
    const target = storage ?? (typeof window !== 'undefined' ? window.sessionStorage : undefined)
    return target?.getItem(SESSION_TOKEN_KEY)?.trim() ?? ''
  } catch {
    return ''
  }
}

export function writeSessionToken(
  token: string,
  storage?: Pick<Storage, 'setItem' | 'removeItem'>,
): void {
  try {
    const target = storage ?? (typeof window !== 'undefined' ? window.sessionStorage : undefined)
    const trimmed = token.trim()
    if (!trimmed) target?.removeItem(SESSION_TOKEN_KEY)
    else target?.setItem(SESSION_TOKEN_KEY, trimmed)
  } catch {
    // Ignore storage errors in restricted browsing contexts.
  }
}

export function validateSettingsInput(
  input: ComputerSettings,
  limits: ComputerLimits = DEFAULT_LIMITS,
): { ok: true; value: ComputerSettings } | { ok: false; errors: Partial<Record<keyof ComputerSettings, string>> } {
  const errors: Partial<Record<keyof ComputerSettings, string>> = {}
  const name = input.name.trim()
  if (name.length < 1 || name.length > 80) {
    errors.name = 'Computer name must be between 1 and 80 characters.'
  } else if (CONTROL_CHAR_PATTERN.test(name)) {
    errors.name = 'Computer name cannot contain control characters.'
  }

  if (
    !Number.isSafeInteger(input.memoryMb) ||
    input.memoryMb < limits.memoryMb.min ||
    input.memoryMb > limits.memoryMb.max
  ) {
    errors.memoryMb = `Memory must be an integer from ${limits.memoryMb.min} to ${limits.memoryMb.max} MiB.`
  }

  if (!Number.isSafeInteger(input.vcpus) || input.vcpus < limits.vcpus.min || input.vcpus > limits.vcpus.max) {
    errors.vcpus = `vCPUs must be an integer from ${limits.vcpus.min} to ${limits.vcpus.max}.`
  }

  if (!Number.isSafeInteger(input.idleMs) || input.idleMs < limits.idleMs.min || input.idleMs > limits.idleMs.max) {
    const minMinutes = Math.round(limits.idleMs.min / 60_000)
    const maxHours = Math.round(limits.idleMs.max / 3_600_000)
    errors.idleMs = `Idle timeout must be between ${minMinutes} min and ${maxHours} hr (${limits.idleMs.min}–${limits.idleMs.max} ms).`
  }

  if (Object.keys(errors).length > 0) {
    return { ok: false, errors }
  }

  return {
    ok: true,
    value: {
      name,
      memoryMb: input.memoryMb,
      vcpus: input.vcpus,
      idleMs: input.idleMs,
    },
  }
}

export function computeSettingsPatch(
  current: ComputerSettings,
  next: ComputerSettings,
): Partial<ComputerSettings> {
  const patch: Partial<ComputerSettings> = {}
  const trimmedName = next.name.trim()
  if (trimmedName !== current.name) patch.name = trimmedName
  if (next.memoryMb !== current.memoryMb) patch.memoryMb = next.memoryMb
  if (next.vcpus !== current.vcpus) patch.vcpus = next.vcpus
  if (next.idleMs !== current.idleMs) patch.idleMs = next.idleMs
  return patch
}

export function willRequireColdRestart(
  status: Pick<ComputerStatus, 'activeResources' | 'restartRequired'>,
  next: Pick<ComputerSettings, 'memoryMb' | 'vcpus'>,
): boolean {
  if (!status.activeResources) return status.restartRequired
  return (
    status.activeResources.memoryMb !== next.memoryMb ||
    status.activeResources.vcpus !== next.vcpus
  )
}

export function formatMemoryMb(memoryMb: number): string {
  if (memoryMb >= 1024 && memoryMb % 1024 === 0) {
    return `${memoryMb / 1024} GiB`
  }
  if (memoryMb >= 1024) {
    return `${(memoryMb / 1024).toFixed(1)} GiB (${memoryMb} MiB)`
  }
  return `${memoryMb} MiB`
}

export function formatIdleDuration(idleMs: number): string {
  const totalMinutes = Math.round(idleMs / 60_000)
  if (totalMinutes < 60) return `${totalMinutes} min`
  const hours = Math.floor(totalMinutes / 60)
  const minutes = totalMinutes % 60
  return minutes === 0 ? `${hours} hr` : `${hours} hr ${minutes} min`
}

/**
 * The link Caboose on an iPhone opens to sign in: the host's address and a pairing code it
 * trades through `POST /v1/pair` for its own token. It never carries a token.
 */
export function buildPairingLink(hosts: string | readonly string[], code: string): string {
  // Every address the phone may reach the host at: the first as `host`, the rest as `alt`.
  const [host = '', ...alternates] = (typeof hosts === 'string' ? [hosts] : hosts).map(url => url.replace(/\/+$/, ''))
  const params = new URLSearchParams({ host })
  for (const alternate of alternates) params.append('alt', alternate)
  params.append('code', code.trim())
  return `caboose://connect?${params.toString()}`
}

/** `GET /v1/host/reach`: every address a phone can use, best first, and how each is provided. */
export interface Reach {
  addresses: Array<{ url: string; kind: 'public' | 'tailscale' | 'lan' }>
  mdns: { enabled: boolean; name: string | null }
  tailscale: { installed: boolean; loggedIn: boolean; name?: string; serving: boolean; httpsUrl?: string; error?: string }
}

/** A code as people read it aloud: two groups of four. */
export function formatPairingCode(code: string): string {
  return code.length === 8 ? `${code.slice(0, 4)}-${code.slice(4)}` : code
}

export class CabooseApiError extends Error {
  constructor(
    public readonly status: number,
    message: string,
  ) {
    super(message)
    this.name = 'CabooseApiError'
  }

  /** The host rejected the token. A 403 is not this: the file service uses it for a permission the computer denies. */
  get isUnauthorized(): boolean {
    return this.status === 401
  }

  get isConflict(): boolean {
    return this.status === 409
  }
}

/** Routes about the host and its computers, never scoped to one computer. */
function isHostPath(path: string): boolean {
  return path === '/v1/health' || path === '/v1/host' || path === '/v1/computers' || path === '/v1/me'
    || ['/v1/host/', '/v1/computers/', '/v1/tenants', '/v1/setup', '/v1/invites/', '/v1/auth/'].some(prefix => path.startsWith(prefix))
}

export class CabooseClient {
  constructor(
    private readonly getToken: () => string,
    private readonly baseUrl = '',
    // Browsers reject a native fetch called with any receiver but the window, so never call it as a method.
    private readonly fetchImpl: typeof fetch = (input, init) => globalThis.fetch(input, init),
    /** The computer this client's computer routes go to; the owner token's own computer when absent. */
    readonly computerId?: string,
  ) {}

  /** The same client, with its computer routes sent to `/v1/computers/<id>/…`. */
  forComputer(id: string): CabooseClient {
    return new CabooseClient(this.getToken, this.baseUrl, this.fetchImpl, id)
  }

  private route(path: string): string {
    if (!this.computerId || isHostPath(path) || !path.startsWith('/v1/')) return path
    return `/v1/computers/${encodeURIComponent(this.computerId)}${path.slice(3)}`
  }

  /** Sends a request and returns the successful response; failures become CabooseApiError. */
  private async send(
    method: string,
    path: string,
    options: { body?: BodyInit; headers?: Record<string, string>; timeoutMs?: number; accept?: string } = {},
  ): Promise<Response> {
    const token = this.getToken().trim()
    const controller = new AbortController()
    const timeoutMs = options.timeoutMs ?? 30_000
    const timer = setTimeout(() => controller.abort(), timeoutMs)

    try {
      const headers: Record<string, string> = {
        Accept: options.accept ?? 'application/json',
        ...options.headers,
      }
      if (token) {
        headers.Authorization = `Bearer ${token}`
      }

      const fetchImpl = this.fetchImpl
      const response = await fetchImpl(`${this.baseUrl}${this.route(path)}`, {
        method,
        headers,
        body: options.body,
        signal: controller.signal,
      })

      if (!response.ok) {
        const text = await response.text()
        let parsed: unknown = undefined
        try {
          parsed = text ? JSON.parse(text) : undefined
        } catch {
          parsed = undefined
        }
        // The host answers { error }; its sign-in routes (Better Auth) answer { message }.
        const body = parsed && typeof parsed === 'object' ? parsed as { error?: unknown; message?: unknown } : {}
        const message = typeof body.error === 'string' ? body.error : typeof body.message === 'string' ? body.message : `Request failed (${response.status})`
        throw new CabooseApiError(response.status, message)
      }

      // The caller reads the body, so the timeout keeps covering a slow download.
      const body = response.body
      if (!body) return response
      const timed = body.pipeThrough(new TransformStream({ flush: () => clearTimeout(timer) }))
      return new Response(timed, { status: response.status, statusText: response.statusText, headers: response.headers })
    } catch (error) {
      clearTimeout(timer)
      if (error instanceof CabooseApiError) throw error
      if (error instanceof Error && error.name === 'AbortError') {
        throw new CabooseApiError(408, 'The computer operation timed out.')
      }
      throw new CabooseApiError(0, error instanceof Error ? error.message : 'Network error')
    }
  }

  private async request<T>(
    method: string,
    path: string,
    options: { body?: unknown; timeoutMs?: number } = {},
  ): Promise<T> {
    const response = await this.send(method, path, {
      ...(options.body !== undefined ? { body: JSON.stringify(options.body), headers: { 'Content-Type': 'application/json' } } : {}),
      ...(options.timeoutMs !== undefined ? { timeoutMs: options.timeoutMs } : {}),
    })
    let text: string
    try {
      text = await response.text()
    } catch (error) {
      if (error instanceof Error && error.name === 'AbortError') throw new CabooseApiError(408, 'The computer operation timed out.')
      throw new CabooseApiError(0, error instanceof Error ? error.message : 'Network error')
    }
    if (!text) return undefined as T
    try {
      return JSON.parse(text) as T
    } catch {
      return undefined as T
    }
  }

  computers(): Promise<ComputersResponse> {
    return this.request<ComputersResponse>('GET', '/v1/computers', { timeoutMs: 20_000 })
  }

  createComputer(input: NewComputer): Promise<ComputerSummary> {
    return this.request<ComputerSummary>('POST', '/v1/computers', { body: input, timeoutMs: 60_000 })
  }

  /** A computer's person, and (for the operator) its tenant. */
  updateComputer(id: string, changes: { person?: string | null; tenantId?: string }): Promise<ComputerSummary> {
    return this.request<ComputerSummary>('PATCH', `/v1/computers/${encodeURIComponent(id)}`, { body: changes, timeoutMs: 20_000 })
  }

  me(): Promise<Me> {
    return this.request<Me>('GET', '/v1/me', { timeoutMs: 15_000 })
  }

  setupStatus(): Promise<{ claimed: boolean; codeRequired: boolean }> {
    return this.request<{ claimed: boolean; codeRequired: boolean }>('GET', '/v1/setup', { timeoutMs: 15_000 })
  }

  /** Makes the operator's account and first tenant; the answer signs this browser in. */
  setUp(input: SetupInput): Promise<{ claimed: true }> {
    return this.request<{ claimed: true }>('POST', '/v1/setup', { body: input, timeoutMs: 60_000 })
  }

  signIn(email: string, password: string): Promise<unknown> {
    return this.request<unknown>('POST', '/v1/auth/sign-in/email', { body: { email, password }, timeoutMs: 30_000 })
  }

  signOut(): Promise<unknown> {
    return this.request<unknown>('POST', '/v1/auth/sign-out', { body: {}, timeoutMs: 15_000 })
  }

  invitation(token: string): Promise<InviteDetails> {
    return this.request<InviteDetails>('GET', `/v1/invites/${encodeURIComponent(token)}`, { timeoutMs: 15_000 })
  }

  /** A new administrator gives a name and password; one with an account gives its password. */
  acceptInvitation(token: string, input: { name?: string; password: string }): Promise<{ accepted: true }> {
    return this.request<{ accepted: true }>('POST', `/v1/invites/${encodeURIComponent(token)}/accept`, { body: input, timeoutMs: 30_000 })
  }

  tenants(): Promise<{ tenants: Tenant[] }> {
    return this.request<{ tenants: Tenant[] }>('GET', '/v1/tenants', { timeoutMs: 20_000 })
  }

  createTenant(input: { name: string; quotas: Quotas }): Promise<Tenant> {
    return this.request<Tenant>('POST', '/v1/tenants', { body: input, timeoutMs: 20_000 })
  }

  updateTenant(id: string, changes: { name?: string; quotas?: Partial<Quotas> }): Promise<Tenant> {
    return this.request<Tenant>('PATCH', `/v1/tenants/${encodeURIComponent(id)}`, { body: changes, timeoutMs: 20_000 })
  }

  deleteTenant(id: string): Promise<{ deleted: true }> {
    return this.request<{ deleted: true }>('DELETE', `/v1/tenants/${encodeURIComponent(id)}`, { timeoutMs: 20_000 })
  }

  administrators(tenantId: string): Promise<{ administrators: Administrator[] }> {
    return this.request<{ administrators: Administrator[] }>('GET', `/v1/tenants/${encodeURIComponent(tenantId)}/administrators`, { timeoutMs: 15_000 })
  }

  removeAdministrator(tenantId: string, userId: string): Promise<{ removed: true }> {
    return this.request<{ removed: true }>('DELETE', `/v1/tenants/${encodeURIComponent(tenantId)}/administrators/${encodeURIComponent(userId)}`, { timeoutMs: 15_000 })
  }

  invites(tenantId: string): Promise<{ invites: PendingInvite[] }> {
    return this.request<{ invites: PendingInvite[] }>('GET', `/v1/tenants/${encodeURIComponent(tenantId)}/invites`, { timeoutMs: 15_000 })
  }

  /** Makes an invitation; its token is in this answer only, so the link is shown once. */
  invite(tenantId: string, email: string): Promise<{ invite: PendingInvite; token: string }> {
    return this.request<{ invite: PendingInvite; token: string }>('POST', `/v1/tenants/${encodeURIComponent(tenantId)}/invites`, { body: { email }, timeoutMs: 15_000 })
  }

  revokeInvite(tenantId: string, inviteId: string): Promise<{ revoked: true }> {
    return this.request<{ revoked: true }>('DELETE', `/v1/tenants/${encodeURIComponent(tenantId)}/invites/${encodeURIComponent(inviteId)}`, { timeoutMs: 15_000 })
  }

  /** Deletes a computer with its disk; the host waits for work already running on it. */
  deleteComputer(id: string): Promise<{ deleted: true }> {
    return this.request<{ deleted: true }>('DELETE', `/v1/computers/${encodeURIComponent(id)}`, { body: { confirm: true }, timeoutMs: 300_000 })
  }

  phones(id: string): Promise<{ phones: PhoneSignIn[] }> {
    return this.request<{ phones: PhoneSignIn[] }>('GET', `/v1/computers/${encodeURIComponent(id)}/phones`, { timeoutMs: 15_000 })
  }

  /** A single-use code that signs one phone in to the computer, valid for ten minutes. */
  startPairing(id: string): Promise<PairingCode> {
    return this.request<PairingCode>('POST', `/v1/computers/${encodeURIComponent(id)}/pairing`, { timeoutMs: 15_000 })
  }

  removePhone(id: string, phoneId: string): Promise<{ revoked: true }> {
    return this.request<{ revoked: true }>('DELETE', `/v1/computers/${encodeURIComponent(id)}/phones/${encodeURIComponent(phoneId)}`, { timeoutMs: 15_000 })
  }

  computer(): Promise<ComputerStatus> {
    return this.request<ComputerStatus>('GET', '/v1/computer', { timeoutMs: 20_000 })
  }

  updateSettings(patch: Partial<ComputerSettings>): Promise<ComputerStatus> {
    return this.request<ComputerStatus>('PATCH', '/v1/computer/settings', { body: patch, timeoutMs: 20_000 })
  }

  restart(): Promise<ComputerStatus> {
    return this.request<ComputerStatus>('POST', '/v1/computer/restart', {
      body: { confirm: true },
      timeoutMs: 300_000,
    })
  }

  wake(): Promise<SessionInfo> {
    return this.request<SessionInfo>('POST', '/v1/session', { timeoutMs: 300_000 })
  }

  park(): Promise<{ state: ComputerState }> {
    return this.request<{ state: ComputerState }>('POST', '/v1/session/park', { timeoutMs: 120_000 })
  }

  health(): Promise<HealthStatus> {
    return this.request<HealthStatus>('GET', '/v1/health', { timeoutMs: 15_000 })
  }

  host(): Promise<HostInfo> {
    return this.request<HostInfo>('GET', '/v1/host', { timeoutMs: 15_000 })
  }

  /** Where phones can reach this host (docs/architecture.md, Reachability). */
  reach(): Promise<Reach> {
    return this.request<Reach>('GET', '/v1/host/reach', { timeoutMs: 20_000 })
  }

  /** Turns Tailscale's HTTPS serve for this host on or off. */
  setTailscale(enabled: boolean): Promise<Reach> {
    return this.request<Reach>('PUT', '/v1/host/reach/tailscale', { body: { enabled }, timeoutMs: 30_000 })
  }

  pushDevices(): Promise<{ devices: PushDevice[] }> {
    return this.request<{ devices: PushDevice[] }>('GET', '/v1/devices/push', { timeoutMs: 15_000 })
  }

  removePushDevice(id: string): Promise<{ removed: true }> {
    return this.request<{ removed: true }>('DELETE', `/v1/devices/push/${encodeURIComponent(id)}`, { timeoutMs: 15_000 })
  }

  /** The catalog with installed versions and operation state; the last observed state while parked. */
  catalog(): Promise<CatalogResponse> {
    return this.request<CatalogResponse>('GET', '/v1/catalog', { timeoutMs: 60_000 })
  }

  /** Queues an operation; the host answers 202 and the catalog then reports its progress. */
  startCatalogOperation(id: string, operation: CatalogOperation): Promise<{ accepted: true }> {
    const app = `/v1/catalog/${encodeURIComponent(id)}`
    return operation === 'remove'
      ? this.request<{ accepted: true }>('DELETE', app, { timeoutMs: 30_000 })
      : this.request<{ accepted: true }>('POST', `${app}/${operation}`, { timeoutMs: 30_000 })
  }

  installPack(id: string): Promise<{ accepted: true }> {
    return this.request<{ accepted: true }>('POST', `/v1/catalog/packs/${encodeURIComponent(id)}/install`, { timeoutMs: 30_000 })
  }

  /** Lists a home-relative folder. Every /v1/fs request wakes a parked computer. */
  async listFiles(path: string): Promise<FileItem[]> {
    const { items } = await this.request<{ items: FileItem[] }>('GET', `/v1/fs/list?${fsQuery(path)}`, { timeoutMs: 300_000 })
    return items
  }

  /** Streams a file's bytes; the caller reads the body. */
  downloadFile(path: string): Promise<Response> {
    return this.send('GET', `/v1/fs/content?${fsQuery(path)}`, { accept: '*/*', timeoutMs: 3_600_000 })
  }

  /**
   * Uploads a new file into a folder without replacing anything: a taken name becomes
   * "name (2).ext", as the host's own Downloads uploads do. Returns the path it was saved at.
   */
  async uploadFile(directory: string, name: string, body: Blob): Promise<string> {
    for (let n = 1; n <= 100; n++) {
      const path = joinPath(directory, numberedName(name, n))
      try {
        await this.send('PUT', `/v1/fs/content?${fsQuery(path)}`, {
          body,
          headers: { 'If-None-Match': '*', 'Content-Type': body.type || 'application/octet-stream' },
          timeoutMs: 3_600_000,
        })
        return path
      } catch (failure) {
        if (failure instanceof CabooseApiError && (failure.status === 412 || failure.status === 409)) continue
        throw failure
      }
    }
    throw new CabooseApiError(409, `Too many files named like ${name} already exist here.`)
  }

  createFolder(path: string): Promise<FileItem> {
    return this.request<FileItem>('POST', `/v1/fs/mkdir?${fsQuery(path)}`, { timeoutMs: 300_000 })
  }

  moveFile(path: string, destination: string): Promise<FileItem> {
    return this.request<FileItem>('POST', `/v1/fs/move?${fsQuery(path)}`, { body: { destination }, timeoutMs: 300_000 })
  }

  /** Moves an item to the computer's Trash. */
  trashFile(path: string): Promise<{ deleted: true }> {
    return this.request<{ deleted: true }>('DELETE', `/v1/fs/item?${fsQuery(path)}`, { timeoutMs: 300_000 })
  }
}
