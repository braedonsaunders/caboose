import { randomUUID } from 'node:crypto'
import { mkdir, open, unlink } from 'node:fs/promises'
import { dirname } from 'node:path'

export interface FreezeBranch { path: string; frozen: boolean }
export type ParkedFreezeIntent = { version: 1; id: string } | { version: 2; id: string; branches: FreezeBranch[]; homeDevice?: number }
const MAX_INTENT_BYTES = 128 * 1024

function validateBranches(value: unknown): FreezeBranch[] {
  if (!Array.isArray(value) || value.length > 256) throw new Error('Invalid parked Files recovery intent')
  const branches: FreezeBranch[] = []
  for (const entry of value) {
    if (!entry || typeof entry !== 'object' || Array.isArray(entry) || Object.keys(entry).sort().join(',') !== 'frozen,path' || typeof entry.path !== 'string' || typeof entry.frozen !== 'boolean' || entry.path.length > 200 || !/^\/(?:[A-Za-z0-9_:@.-]|\\x(?!00|2f)[0-9a-f]{2})+(?:\/(?:[A-Za-z0-9_:@.-]|\\x(?!00|2f)[0-9a-f]{2})+)*$/.test(entry.path) || entry.path.split('/').some((part: string) => part === '.' || part === '..')) throw new Error('Invalid parked Files recovery intent')
    if (branches.some(other => other.path === entry.path || other.path.startsWith(entry.path + '/') || entry.path.startsWith(other.path + '/'))) throw new Error('Invalid parked Files recovery intent')
    branches.push({ path: entry.path, frozen: entry.frozen })
  }
  return branches
}

async function syncDirectory(path: string): Promise<void> {
  const dir = await open(dirname(path), 'r')
  try { await dir.sync() } finally { await dir.close() }
}

/** Persistent intent is written before guest freezing and removed only after verified thaw.
 * The caller serializes this journal with the computer's lifecycle transitions. */
export class ParkedFilesJournal {
  constructor(private readonly path: string) {}

  async begin(branches?: FreezeBranch[], homeDevice?: number): Promise<ParkedFreezeIntent> {
    await mkdir(dirname(this.path), { recursive: true, mode: 0o700 })
    if (homeDevice !== undefined && (!Number.isSafeInteger(homeDevice) || homeDevice < 0 || branches === undefined)) throw new Error('Invalid parked Files recovery intent')
    const intent: ParkedFreezeIntent = branches === undefined ? { version: 1, id: randomUUID() } : { version: 2, id: randomUUID(), branches: validateBranches(branches), ...(homeDevice === undefined ? {} : { homeDevice }) }
    const file = await open(this.path, 'wx', 0o600)
    try { await file.writeFile(JSON.stringify(intent) + '\n'); await file.sync() }
    finally { await file.close() }
    // If this fails the marker may exist: callers must treat it as requiring recovery.
    await syncDirectory(this.path)
    return intent
  }

  async read(): Promise<ParkedFreezeIntent | undefined> {
    let file
    try { file = await open(this.path, 'r') }
    catch (error) { if ((error as NodeJS.ErrnoException).code === 'ENOENT') return undefined; throw error }
    const buffer = Buffer.alloc(MAX_INTENT_BYTES + 1)
    let bytesRead: number
    try { ({ bytesRead } = await file.read(buffer, 0, buffer.length, 0)) } finally { await file.close() }
    if (bytesRead > MAX_INTENT_BYTES) throw new Error('Invalid parked Files recovery intent')
    const raw = buffer.subarray(0, bytesRead).toString('utf8')
    let value: unknown
    try { value = JSON.parse(raw) } catch { throw new Error('Invalid parked Files recovery intent') }
    if (!value || typeof value !== 'object' || Array.isArray(value)) throw new Error('Invalid parked Files recovery intent')
    const record = value as Record<string, unknown>
    if (typeof record.id !== 'string' || !/^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/.test(record.id)) throw new Error('Invalid parked Files recovery intent')
    if (record.version === 1 && Object.keys(record).sort().join(',') === 'id,version') return { version: 1, id: record.id }
    if (record.version === 2 && ['branches,id,version', 'branches,homeDevice,id,version'].includes(Object.keys(record).sort().join(','))) {
      if (record.homeDevice !== undefined && (typeof record.homeDevice !== 'number' || !Number.isSafeInteger(record.homeDevice) || record.homeDevice < 0)) throw new Error('Invalid parked Files recovery intent')
      return { version: 2, id: record.id, branches: validateBranches(record.branches), ...(record.homeDevice === undefined ? {} : { homeDevice: record.homeDevice as number }) }
    }
    throw new Error('Invalid parked Files recovery intent')
  }

  async clear(id: string): Promise<void> {
    const current = await this.read()
    if (!current || current.id !== id) throw new Error('Parked Files recovery intent changed')
    await unlink(this.path)
    await syncDirectory(this.path)
  }
}
