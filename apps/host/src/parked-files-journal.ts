import { randomUUID } from 'node:crypto'
import { mkdir, open, unlink } from 'node:fs/promises'
import { dirname } from 'node:path'

export interface ParkedFreezeIntent { version: 1; id: string }

async function syncDirectory(path: string): Promise<void> {
  const dir = await open(dirname(path), 'r')
  try { await dir.sync() } finally { await dir.close() }
}

/** Persistent intent is written before guest freezing and removed only after verified thaw.
 * The caller serializes this journal with the computer's lifecycle transitions. */
export class ParkedFilesJournal {
  constructor(private readonly path: string) {}

  async begin(): Promise<ParkedFreezeIntent> {
    await mkdir(dirname(this.path), { recursive: true, mode: 0o700 })
    const intent: ParkedFreezeIntent = { version: 1, id: randomUUID() }
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
    const buffer = Buffer.alloc(1025)
    let bytesRead: number
    try { ({ bytesRead } = await file.read(buffer, 0, buffer.length, 0)) } finally { await file.close() }
    if (bytesRead > 1024) throw new Error('Invalid parked Files recovery intent')
    const raw = buffer.subarray(0, bytesRead).toString('utf8')
    let value: unknown
    try { value = JSON.parse(raw) } catch { throw new Error('Invalid parked Files recovery intent') }
    if (!value || typeof value !== 'object' || Array.isArray(value)) throw new Error('Invalid parked Files recovery intent')
    const record = value as Record<string, unknown>
    if (Object.keys(record).sort().join(',') !== 'id,version' || record.version !== 1 || typeof record.id !== 'string' || !/^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/.test(record.id)) throw new Error('Invalid parked Files recovery intent')
    return { version: 1, id: record.id }
  }

  async clear(id: string): Promise<void> {
    const current = await this.read()
    if (!current || current.id !== id) throw new Error('Parked Files recovery intent changed')
    await unlink(this.path)
    await syncDirectory(this.path)
  }
}
