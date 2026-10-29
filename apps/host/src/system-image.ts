import { createHash } from 'node:crypto'
import { createReadStream } from 'node:fs'
import { access, open, readFile } from 'node:fs/promises'
import { dirname, isAbsolute, join, resolve } from 'node:path'
import { writePrivateJson } from './settings.js'

const files = ['base.raw', 'vmlinux', 'initrd', 'system.erofs'] as const
type ImageFile = typeof files[number]
export interface SystemImageBinding { version: 1; directory: string; hashes: Record<ImageFile, string> }

async function exists(path: string): Promise<boolean> {
  try { await access(path); return true } catch (error) {
    if ((error as NodeJS.ErrnoException).code === 'ENOENT') return false
    throw error
  }
}
async function digest(path: string): Promise<string> {
  const hash = createHash('sha256')
  for await (const chunk of createReadStream(path)) hash.update(chunk as Buffer)
  return hash.digest('hex')
}
function parse(value: unknown): SystemImageBinding {
  const b = value as SystemImageBinding
  if (!b || b.version !== 1 || typeof b.directory !== 'string' || !isAbsolute(b.directory) || !b.hashes || files.some(file => !/^[a-f0-9]{64}$/.test(b.hashes[file]))) throw new Error('Invalid saved system image binding')
  return b
}
export async function usesSystemImage(bindingPath: string, diskPath: string, snapshotPath: string, selected?: string): Promise<boolean> {
  if (await exists(bindingPath)) return true
  return Boolean(selected) && !(await exists(diskPath)) && !(await exists(snapshotPath))
}
/** Bind only a computer with no disk or snapshot. A saved binding always wins over configuration. */
export async function selectSystemImage(bindingPath: string, diskPath: string, snapshotPath: string, selected?: string): Promise<SystemImageBinding | null> {
  let binding: SystemImageBinding | undefined
  try { binding = parse(JSON.parse(await readFile(bindingPath, 'utf8'))) }
  catch (error) { if ((error as NodeJS.ErrnoException).code !== 'ENOENT') throw error }
  if (!binding) {
    if (!selected || await exists(diskPath) || await exists(snapshotPath)) return null
    const directory = resolve(selected)
    const hashes = {} as Record<ImageFile, string>
    for (const file of files) hashes[file] = await digest(join(directory, file))
    binding = { version: 1, directory, hashes }
    await writePrivateJson(bindingPath, binding)
    // The binding must survive a crash before the raw overlay is created.
    const directoryHandle = await open(dirname(bindingPath), 'r')
    try { await directoryHandle.sync() } finally { await directoryHandle.close() }
  }
  const diskExists = await exists(diskPath)
  for (const file of files) if ((file !== 'base.raw' || !diskExists) && await digest(join(binding.directory, file)) !== binding.hashes[file]) throw new Error(`Computer's retained system image changed: ${join(binding.directory, file)}`)
  return binding
}
