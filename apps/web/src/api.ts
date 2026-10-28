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

export function buildIosPairingUrl(hostOrigin: string, token: string): string {
  const params = new URLSearchParams({
    host: hostOrigin.replace(/\/+$/, ''),
    token: token.trim(),
  })
  return `caboose://connect?${params.toString()}`
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

export class CabooseClient {
  constructor(
    private readonly getToken: () => string,
    private readonly baseUrl = '',
    // Browsers reject a native fetch called with any receiver but the window, so never call it as a method.
    private readonly fetchImpl: typeof fetch = (input, init) => globalThis.fetch(input, init),
  ) {}

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
      const response = await fetchImpl(`${this.baseUrl}${path}`, {
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
        const message =
          parsed && typeof parsed === 'object' && 'error' in parsed && typeof (parsed as { error: unknown }).error === 'string'
            ? (parsed as { error: string }).error
            : `Request failed (${response.status})`
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
