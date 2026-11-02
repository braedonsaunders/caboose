import { access, mkdir, rename } from 'node:fs/promises'
import { join } from 'node:path'
import { COMPUTER_ID_PATTERN, LEGACY_COMPUTER, LEGACY_ROOT_FILES, type ComputerRegistry } from './computers.js'
import { readJsonFile, SettingsInputError, writePrivateJson } from './settings.js'

/**
 * What belongs to the host rather than to any computer, kept in `host.json`: the name phones
 * list it by (null shows `Caboose on <machine>`), and the default computer, which the routes
 * without a computer in their path serve to the owner token, the operator and host phones.
 */
export interface HostSettingsValue { name: string | null; defaultComputer: string | null }

function hostName(value: unknown): string | null {
  if (value === null || value === undefined) return null
  if (typeof value !== 'string' || !value.trim() || value.trim().length > 80 || /[\u0000-\u001f\u007f]/.test(value)) {
    throw new SettingsInputError('name must be 1–80 characters without control characters, or null')
  }
  return value.trim()
}

function computerId(value: unknown): string | null {
  if (value === null || value === undefined) return null
  if (typeof value !== 'string' || !COMPUTER_ID_PATTERN.test(value)) throw new SettingsInputError('defaultComputer must be a computer id or null')
  return value
}

export class HostSettings {
  private pending: Promise<void> = Promise.resolve()
  private constructor(private path: string | null, private value: HostSettingsValue) {}

  static async open(path: string): Promise<HostSettings> {
    const stored = await readJsonFile(path)
    if (stored !== undefined && (!stored || typeof stored !== 'object' || Array.isArray(stored))) throw new Error('Host settings must be a JSON object')
    const v = (stored ?? {}) as Record<string, unknown>
    return new HostSettings(path, { name: hostName(v.name), defaultComputer: computerId(v.defaultComputer) })
  }

  /** Settings kept in memory only (tests). */
  static memory(value: Partial<HostSettingsValue> = {}): HostSettings {
    return new HostSettings(null, { name: value.name ?? null, defaultComputer: value.defaultComputer ?? null })
  }

  get(): HostSettingsValue { return { ...this.value } }

  /** Changes the fields given; `exists` says whether a computer id names a computer. */
  async update(input: Record<string, unknown>, exists: (id: string) => boolean = () => true): Promise<HostSettingsValue> {
    for (const key of Object.keys(input)) if (key !== 'name' && key !== 'defaultComputer') throw new SettingsInputError(`Unknown setting: ${key}`)
    const next = { ...this.value }
    if ('name' in input) next.name = hostName(input.name)
    if ('defaultComputer' in input) {
      next.defaultComputer = computerId(input.defaultComputer)
      if (next.defaultComputer && !exists(next.defaultComputer)) throw new SettingsInputError('computer not found')
    }
    return this.write(next)
  }

  private write(next: HostSettingsValue): Promise<HostSettingsValue> {
    const work = this.pending.then(async () => {
      if (this.path) await writePrivateJson(this.path, next)
      this.value = next
      return { ...next }
    })
    this.pending = work.then(() => {}, () => {})
    return work
  }

  /** Points the default at a computer when there is none, as making a computer does. */
  async adopt(id: string): Promise<void> {
    if (!this.value.defaultComputer) await this.write({ ...this.value, defaultComputer: id })
  }

  /** A deleted default gives way to the next computer, or to none. */
  async forget(id: string, next: string | null): Promise<void> {
    if (this.value.defaultComputer === id) await this.write({ ...this.value, defaultComputer: next })
  }
}

/**
 * Settles a host from before computers were equal, once its registry is open. Its built-in
 * computer stays an ordinary computer under the legacy id, and its files move from the image
 * root to `computers/owner/` like any computer's; nothing is deleted, and a move interrupted
 * by a crash finishes on the next start. The host takes over what that computer carried for
 * it: its name becomes the host's name, and it becomes the default computer.
 */
export async function settleLegacyComputer(root: string, computers: ComputerRegistry): Promise<void> {
  const hostFile = join(root, 'host.json')
  const legacy = computers.get(LEGACY_COMPUTER)
  if (!legacy) return
  const dir = computers.dataDir(LEGACY_COMPUTER)
  if (!await present(hostFile)) {
    const settings = await readJsonFile(join(root, 'caboose.json')) ?? await readJsonFile(join(dir, 'caboose.json'))
    const name = settings && typeof settings === 'object' && typeof (settings as { name?: unknown }).name === 'string' ? (settings as { name: string }).name : 'Caboose'
    await writePrivateJson(hostFile, { name: name === 'Caboose' ? null : name, defaultComputer: LEGACY_COMPUTER })
  }
  await mkdir(dir, { recursive: true, mode: 0o700 })
  for (const name of LEGACY_ROOT_FILES) {
    const from = join(root, name), to = join(dir, name)
    if (await present(from) && !await present(to)) await rename(from, to)
  }
  // The built-in computer was called Caboose until its owner renamed it; keep that name.
  if (!await present(join(dir, 'caboose.json'))) await writePrivateJson(join(dir, 'caboose.json'), { name: 'Caboose' })
}

async function present(path: string): Promise<boolean> {
  return access(path).then(() => true, () => false)
}
