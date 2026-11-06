import { readFile } from 'node:fs/promises'
import { parseFolders, type HostFolder } from './container-spec.js'
import { writePrivateJson } from './settings.js'

/**
 * What one microVM computer is started with beyond the host's defaults
 * (docs/architecture.md § Computers): folders of the host, each shared into the computer over
 * virtio-fs and mounted at its target, read-write unless `readOnly`. The host keeps it in the
 * computer's own state (`machine.json`). Only the operator sets it: it reaches into the host.
 * A computer gets a changed list at its next cold start, since a parked computer resumes with
 * the shares it was parked with.
 */
export interface MachineSpec {
  folders?: HostFolder[]
}

export class MachineSpecError extends Error {}

/** Checks a spec field by field; unknown fields are errors. */
export function parseMachineSpec(input: unknown): MachineSpec {
  if (!input || typeof input !== 'object' || Array.isArray(input)) throw new MachineSpecError('The machine settings must be an object')
  const value = input as Record<string, unknown>
  for (const key of Object.keys(value)) if (key !== 'folders') throw new MachineSpecError(`Unknown machine setting: ${key}`)
  if (value.folders === undefined) return {}
  if (!Array.isArray(value.folders) || value.folders.length > 16) throw new MachineSpecError('folders must be a list of at most 16')
  return { folders: parseFolders(value.folders, MachineSpecError) }
}

/** The virtio-fs tag of a computer's folder `index` (at most 36 bytes, as the device allows). */
export const folderTag = (index: number) => `caboose-folder-${index}`

export class MachineSpecStore {
  private constructor(private readonly path: string, private value: MachineSpec) {}

  static async open(path: string): Promise<MachineSpecStore> {
    let raw: string | undefined
    try { raw = await readFile(path, 'utf8') } catch (error) { if ((error as NodeJS.ErrnoException).code !== 'ENOENT') throw error }
    // A damaged file stops the host rather than starting a computer without its folders.
    return new MachineSpecStore(path, raw === undefined ? {} : parseMachineSpec(JSON.parse(raw)))
  }

  get(): MachineSpec { return structuredClone(this.value) }

  async set(input: unknown): Promise<MachineSpec> {
    const next = parseMachineSpec(input)
    await writePrivateJson(this.path, next)
    this.value = next
    return this.get()
  }
}
