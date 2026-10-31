import { constants } from 'node:fs'
import { open, readdir, mkdir, rename, lstat } from 'node:fs/promises'
import { join } from 'node:path'
import { COMMAND_LIMITS, parseCommandRequest, parseGuestResult, type CommandRecord } from '../commands.js'
import { writePrivateJson } from '../settings.js'

export const commandReceiptName = /^command-([0-9a-f]{32})\.json$/
// JSON escaping can expand bounded output (two 1 MiB streams) up to sixfold.
export const maxCommandReceiptBytes = 16 * 1024 * 1024
const fields = ['id','title','script','cwd','inputs','timeout','status','exitCode','signal','error','stdout','stderr','truncated','outputs','createdAt','finishedAt']
export function validateCommandReceipt(value: unknown, id: string): CommandRecord {
  if (!value || typeof value !== 'object' || Array.isArray(value)) throw new Error('Invalid command receipt')
  const v = value as CommandRecord
  if (Object.keys(v).length !== fields.length || Object.keys(v).some(key => !fields.includes(key)) || v.id !== id || v.status === 'running') throw new Error('Invalid or active command receipt')
  parseCommandRequest({ id: v.id, script: v.script, inputs: v.inputs, cwd: v.cwd, timeout: v.timeout })
  parseGuestResult(v)
  if (typeof v.title !== 'string' || Array.from(v.title).length > 100 || typeof v.createdAt !== 'string' || !Number.isFinite(Date.parse(v.createdAt)) || typeof v.finishedAt !== 'string' || !Number.isFinite(Date.parse(v.finishedAt)) || (v.error !== null && (typeof v.error !== 'string' || v.error.length > 500))) throw new Error('Invalid command receipt metadata')
  for (const stream of [v.stdout, v.stderr]) if (typeof stream !== 'string' || Buffer.byteLength(stream) > 3 * COMMAND_LIMITS.outputBytes) throw new Error('Invalid command receipt output')
  return v
}

/** Strict validation, unlike best-effort local history loading; no symlinks or silent drops. */
export async function readCommandReceipt(path: string, id: string): Promise<CommandRecord> {
  const file = await open(path, constants.O_RDONLY | constants.O_NOFOLLOW)
  try {
    const stat = await file.stat()
    if (!stat.isFile() || stat.size < 1 || stat.size > maxCommandReceiptBytes) throw new Error('Invalid command receipt file')
    return validateCommandReceipt(JSON.parse(await file.readFile('utf8')), id)
  } finally { await file.close() }
}

/** Caller holds command quiescence and computer admission until capture settles. */
export async function stageCommandReceipts(dataDir: string, stage: string): Promise<void> {
  const directory = join(dataDir, 'commands')
  const stat = await lstat(directory).catch(error => { if (error.code === 'ENOENT') return undefined; throw error })
  if (!stat) return
  if (!stat.isDirectory() || stat.isSymbolicLink()) throw new Error('Unsupported command receipt directory')
  const entries = await readdir(directory, { withFileTypes: true })
  if (entries.length > COMMAND_LIMITS.kept) throw new Error('Too many command receipts for checkpoint')
  for (const entry of entries) {
    const match = /^([0-9a-f]{32})\.json$/.exec(entry.name)
    if (!match || !entry.isFile()) throw new Error('Unsupported command receipt entry')
    const record = await readCommandReceipt(join(directory, entry.name), match[1]!)
    await writePrivateJson(join(stage, `command-${record.id}.json`), record)
  }
}

/** Runs only in a new, fully verified private restore directory before activation. */
export async function installCommandReceipts(stage: string): Promise<void> {
  const names = (await readdir(stage)).filter(name => commandReceiptName.test(name))
  if (names.length > COMMAND_LIMITS.kept) throw new Error('Too many command receipts for restore')
  const directory = join(stage, 'commands')
  await mkdir(directory, { mode: 0o700 })
  for (const name of names) {
    const id = commandReceiptName.exec(name)![1]!
    await readCommandReceipt(join(stage, name), id)
    await rename(join(stage, name), join(directory, `${id}.json`))
  }
  const handle = await open(directory, 'r')
  try { await handle.sync() } finally { await handle.close() }
}
