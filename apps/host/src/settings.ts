import { randomUUID } from 'node:crypto'
import { mkdir, open, readFile, rename, unlink } from 'node:fs/promises'
import { dirname } from 'node:path'

export interface ComputerSettings {
  name: string
  memoryMb: number
  vcpus: number
  idleMs: number
}

export interface SettingsLimits {
  memoryMb: { min: number; max: number }
  vcpus: { min: number; max: number }
  idleMs: { min: number; max: number }
}

export function settingsLimits(): SettingsLimits {
  return {
    memoryMb: { min: 512, max: 65_536 },
    vcpus: { min: 1, max: 32 },
    idleMs: { min: 60_000, max: 86_400_000 },
  }
}

export class SettingsInputError extends Error {}

/** Validate before persisting anything; unknown fields are errors, not silently ignored knobs. */
export function updateSettings(current: ComputerSettings, input: Record<string, unknown>, limits: SettingsLimits): ComputerSettings {
  const next = { ...current }
  for (const key of Object.keys(input)) {
    if (key === 'name') {
      const name = input.name
      if (typeof name !== 'string' || !name.trim() || name.trim().length > 80 || /[\u0000-\u001f\u007f]/.test(name)) {
        throw new SettingsInputError('name must be 1–80 characters without control characters')
      }
      next.name = name.trim()
    } else if (key === 'memoryMb' || key === 'vcpus' || key === 'idleMs') {
      const value = input[key]
      const { min, max } = limits[key]
      if (typeof value !== 'number' || !Number.isSafeInteger(value) || value < min || value > max) {
        throw new SettingsInputError(`${key} must be an integer between ${min} and ${max}`)
      }
      next[key] = value
    } else {
      throw new SettingsInputError(`Unknown setting: ${key}`)
    }
  }
  return next
}

export interface SettingsPersistence {
  load(): Promise<ComputerSettings | undefined>
  save(settings: ComputerSettings): Promise<void>
}

/** Rename within the same directory leaves either the old complete file or the new one. */
export async function writePrivateJson(path: string, value: unknown): Promise<void> {
  await mkdir(dirname(path), { recursive: true })
  const temporary = `${path}.${randomUUID()}.tmp`
  try {
    const file = await open(temporary, 'wx', 0o600)
    try {
      await file.writeFile(JSON.stringify(value) + '\n', 'utf8')
      await file.sync()
    } finally { await file.close() }
    await rename(temporary, path)
  } finally {
    await unlink(temporary).catch((error: NodeJS.ErrnoException) => { if (error.code !== 'ENOENT') throw error })
  }
}

export async function readJsonFile(path: string): Promise<unknown | undefined> {
  try { return JSON.parse(await readFile(path, 'utf8')) as unknown }
  catch (error) {
    if ((error as NodeJS.ErrnoException).code === 'ENOENT') return undefined
    throw error
  }
}

export async function openSettings(path: string, defaults: ComputerSettings): Promise<SettingsStore> {
  const limits = settingsLimits()
  const persistence: SettingsPersistence = {
    async load() {
      const value = await readJsonFile(path)
      if (value === undefined) return undefined
      if (!value || typeof value !== 'object' || Array.isArray(value)) throw new Error('Computer settings must be a JSON object')
      return updateSettings(defaults, value as Record<string, unknown>, limits)
    },
    save: value => writePrivateJson(path, value),
  }
  // A damaged settings file is an actionable startup failure, never permission to reset it.
  return new SettingsStore(await persistence.load() ?? defaults, limits, persistence)
}

/** Serial writes merge against the last successful save and never publish an unpersisted value. */
export class SettingsStore {
  private pending: Promise<void> = Promise.resolve()

  constructor(private value: ComputerSettings, readonly limits: SettingsLimits, private readonly persistence: SettingsPersistence) {}

  get(): ComputerSettings { return { ...this.value } }

  update(input: Record<string, unknown>): Promise<ComputerSettings> {
    const result = this.pending.then(async () => {
      const next = updateSettings(this.value, input, this.limits)
      await this.persistence.save(next)
      this.value = next
      return this.get()
    })
    this.pending = result.then(() => {}, () => {})
    return result
  }
}
