import { readFile } from 'node:fs/promises'
import { AgentInputError, AgentNotFoundError, AgentOperationError, AgentUnavailableError, type AgentGuest } from './agents.js'
import { loadCatalog } from './app-catalog-data.js'

const formats: Record<string, string[]> = {
  photocraft: ['png', 'jpg', 'tif', 'webp'],
  pdfcraft: ['pdf'],
  lightcraft: ['jpg', 'png', 'tif', 'webp'],
  filmcraft: ['mp4', 'mov'],
}
const operations: Record<string, string> = { photocraft: 'convert', pdfcraft: 'combine', lightcraft: 'render', filmcraft: 'export' }
export interface CraftRequest { job: string; inputs: string[]; format: string }
export function parseCraftRequest(app: string, input: Record<string, unknown>): CraftRequest {
  if (!formats[app]) throw new AgentNotFoundError('No supported Craft operation for this app')
  if (Object.keys(input).some(k => !['job', 'inputs', 'format'].includes(k))) throw new AgentInputError('unknown Craft argument')
  const { job, inputs, format } = input
  if (typeof job !== 'string' || !/^[0-9a-f]{32}$/.test(job)) throw new AgentInputError('invalid job identifier')
  if (!Array.isArray(inputs) || inputs.length < (app === 'pdfcraft' ? 2 : 1) || inputs.length > (app === 'pdfcraft' || app === 'photocraft' ? 20 : 1) ||
      !inputs.every((name, index) => typeof name === 'string' && new RegExp(`^input-${index}\\.[a-z0-9]{1,12}$`).test(name))) throw new AgentInputError('invalid job inputs')
  if (typeof format !== 'string' || !formats[app]!.includes(format)) throw new AgentInputError('unsupported output format')
  if (app === 'pdfcraft' && inputs.some(name => !name.endsWith('.pdf'))) throw new AgentInputError('PDF inputs required')
  if (app === 'filmcraft' && !inputs[0].endsWith('.fcproj')) throw new AgentInputError('FilmCraft project required')
  return { job, inputs: inputs as string[], format }
}

/** Fixed commands, never caller-supplied shell or CLI flags. Guest verifies staged files again. */
export async function runCraft(guest: AgentGuest | undefined, app: string, input: CraftRequest, installed: boolean): Promise<{ outputs: string[]; warnings: string[] }> {
  if (!guest) throw new AgentUnavailableError()
  const entry = loadCatalog().apps.find(value => value.id === app)
  if (!entry || entry.cli !== `${app}-cli` || !installed) throw new AgentNotFoundError('Craft app is not installed')
  const script = await readFile(new URL('./guest-craft.py', import.meta.url), 'utf8')
  try {
    const result = await guest.run('/usr/bin/python3', ['-c', script, JSON.stringify({ app, operation: operations[app], ...input })], 60 * 60_000)
    const parsed = JSON.parse(result) as { outputs: string[]; warnings?: unknown }
    if (!Array.isArray(parsed.outputs) || parsed.outputs.length !== (app === 'photocraft' ? input.inputs.length : 1) || parsed.outputs.some((path, index) => path !== `.caboose-jobs/${input.job}/output-${index}.${input.format}`)) throw new Error('Invalid job output')
    const warnings = Array.isArray(parsed.warnings) ? parsed.warnings.filter((value): value is string => typeof value === 'string').map(value => value.slice(-1000)).slice(0, 20) : []
    return { outputs: parsed.outputs, warnings }
  } catch (error) { throw new AgentOperationError(error instanceof Error ? error.message.slice(-1000) : 'Craft operation failed') }
}
