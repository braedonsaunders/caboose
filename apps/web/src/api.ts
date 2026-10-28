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
  tasks: {
    running: number
    paused: number
  }
  capabilities: {
    restart: boolean
  }
  lastError: string | null
}

export interface HealthStatus {
  host: string
  kvm: boolean
  desk?: Record<string, unknown>
}

export interface SessionInfo {
  state: string
  display: {
    path: string
    token: string
    protocol: 'xpra-ws' | 'caboose-display'
  }
  computer: {
    name: string
    image: string
    memoryMb: number
    vcpus: number
  }
}

export type AgentKind = 'claude' | 'codex'
export type TaskStatus = 'running' | 'paused' | 'succeeded' | 'failed' | 'cancelled'

export interface AgentTask {
  id: string
  agent: AgentKind
  prompt: string
  status: TaskStatus
  startedAt: string
  finishedAt?: string
  summary?: string
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

  get isUnauthorized(): boolean {
    return this.status === 401 || this.status === 403
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

  private async request<T>(
    method: string,
    path: string,
    options: { body?: unknown; timeoutMs?: number } = {},
  ): Promise<T> {
    const token = this.getToken().trim()
    const controller = new AbortController()
    const timeoutMs = options.timeoutMs ?? 30_000
    const timer = setTimeout(() => controller.abort(), timeoutMs)

    try {
      const headers: Record<string, string> = {
        Accept: 'application/json',
      }
      if (token) {
        headers.Authorization = `Bearer ${token}`
      }
      if (options.body !== undefined) {
        headers['Content-Type'] = 'application/json'
      }

      const fetchImpl = this.fetchImpl
      const response = await fetchImpl(`${this.baseUrl}${path}`, {
        method,
        headers,
        body: options.body !== undefined ? JSON.stringify(options.body) : undefined,
        signal: controller.signal,
      })

      const text = await response.text()
      let parsed: unknown = undefined
      if (text) {
        try {
          parsed = JSON.parse(text)
        } catch {
          parsed = undefined
        }
      }

      if (!response.ok) {
        const message =
          parsed && typeof parsed === 'object' && 'error' in parsed && typeof (parsed as { error: unknown }).error === 'string'
            ? (parsed as { error: string }).error
            : `Request failed (${response.status})`
        throw new CabooseApiError(response.status, message)
      }

      return parsed as T
    } catch (error) {
      if (error instanceof CabooseApiError) throw error
      if (error instanceof Error && error.name === 'AbortError') {
        throw new CabooseApiError(408, 'The computer operation timed out.')
      }
      throw new CabooseApiError(0, error instanceof Error ? error.message : 'Network error')
    } finally {
      clearTimeout(timer)
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

  agentTasks(): Promise<AgentTask[]> {
    return this.request<AgentTask[]>('GET', '/v1/agent/tasks', { timeoutMs: 20_000 })
  }

  startAgentTask(input: { prompt: string; agent: AgentKind; cwd?: string }): Promise<{ id: string }> {
    return this.request<{ id: string }>('POST', '/v1/agent/tasks', {
      body: input,
      timeoutMs: 30_000,
    })
  }

  cancelAgentTask(id: string): Promise<{ cancelled: boolean }> {
    return this.request<{ cancelled: boolean }>('POST', `/v1/agent/tasks/${encodeURIComponent(id)}/cancel`, {
      timeoutMs: 20_000,
    })
  }

  pauseAgentTask(id: string): Promise<{ paused: boolean }> {
    return this.request<{ paused: boolean }>('POST', `/v1/agent/tasks/${encodeURIComponent(id)}/pause`, {
      timeoutMs: 20_000,
    })
  }

  resumeAgentTask(id: string): Promise<{ resumed: boolean }> {
    return this.request<{ resumed: boolean }>('POST', `/v1/agent/tasks/${encodeURIComponent(id)}/resume`, {
      timeoutMs: 20_000,
    })
  }
}
