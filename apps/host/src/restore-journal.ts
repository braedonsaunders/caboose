import { createHash } from 'node:crypto'
import { createReadStream } from 'node:fs'
import { lstat, open, readFile, rename, rm, unlink } from 'node:fs/promises'
import { dirname, join } from 'node:path'
import { writePrivateJson } from './settings.js'
import type { SystemImageBinding } from './system-image.js'

/**
 * Installing a restored disk, journaled so a crash at any point either finishes the
 * installation or stops for inspection; it never boots a disk with the wrong image.
 *
 * The journal names the staged disk by device and inode, and the binding it boots with. It is
 * written before anything changes and removed only after the disk and binding are in place and
 * synced. Every later wake, restart or delete of the computer first finishes a journaled
 * installation (`recoverRestoredDisk`); anything it cannot prove refuses with "recovery
 * required" rather than guess.
 */

export interface RestoredDisk { image: string; binding: SystemImageBinding | null }
interface Journal { version: 1; staged: { path: string; dev: number; ino: number }; binding: SystemImageBinding | null }

const FILES = ['base.raw', 'vmlinux', 'initrd', 'system.erofs'] as const

export class RestoreRecoveryError extends Error {}

export interface RestorePaths {
  disk: string
  binding: string
  journal: string
  /** A template computer cold-starts from its disk only once it has been initialized. */
  template?: { initialized: boolean }
}

async function syncDirectory(path: string): Promise<void> {
  const handle = await open(path, 'r')
  try { await handle.sync() } finally { await handle.close() }
}

async function identity(path: string): Promise<{ dev: number; ino: number } | null> {
  try {
    const info = await lstat(path)
    if (!info.isFile()) throw new RestoreRecoveryError(`${path} is not a regular file`)
    return { dev: info.dev, ino: info.ino }
  } catch (error) {
    if ((error as NodeJS.ErrnoException).code === 'ENOENT') return null
    throw error
  }
}

async function sha256(path: string): Promise<string> {
  const hash = createHash('sha256')
  for await (const chunk of createReadStream(path)) hash.update(chunk as Buffer)
  return hash.digest('hex')
}

/** The disk must boot with exactly the image it was made with; check it before changing anything. */
export async function assertRestorable(paths: RestorePaths, restored: RestoredDisk): Promise<void> {
  if (paths.template && !paths.template.initialized) throw new RestoreRecoveryError('Start this computer once before restoring a backup into it')
  const binding = restored.binding
  if (!binding) return
  for (const file of FILES) {
    // The base is checked by the rebuilt disk's manifest; the files it boots with are checked here.
    if (file === 'base.raw') continue
    if (await sha256(join(binding.directory, file)).catch(() => null) !== binding.hashes[file]) throw new RestoreRecoveryError(`The backup's image file ${file} is not on this host`)
  }
}

async function applyBinding(paths: RestorePaths, binding: SystemImageBinding | null): Promise<void> {
  if (binding) await writePrivateJson(paths.binding, binding)
  else await rm(paths.binding, { force: true })
  for (const directory of new Set([dirname(paths.disk), dirname(paths.binding)])) await syncDirectory(directory)
}

async function readJournal(path: string): Promise<Journal | null> {
  let raw: string
  try { raw = await readFile(path, 'utf8') } catch (error) {
    if ((error as NodeJS.ErrnoException).code === 'ENOENT') return null
    throw error
  }
  try {
    const journal = JSON.parse(raw) as Journal
    if (journal?.version === 1 && typeof journal.staged?.path === 'string' && Number.isSafeInteger(journal.staged.dev) && Number.isSafeInteger(journal.staged.ino) && (journal.binding === null || typeof journal.binding?.directory === 'string')) return journal
  } catch {}
  throw new RestoreRecoveryError('The computer has an unreadable restore journal; recovery is required')
}

/** Finish a journaled installation, if there is one. Call before any wake, restart or delete. */
export async function recoverRestoredDisk(paths: RestorePaths): Promise<void> {
  const journal = await readJournal(paths.journal)
  if (!journal) return
  const staged = await identity(journal.staged.path)
  const disk = await identity(paths.disk)
  const same = (value: { dev: number; ino: number } | null) => value?.dev === journal.staged.dev && value.ino === journal.staged.ino
  if (same(staged)) await rename(journal.staged.path, paths.disk)
  else if (!same(disk)) throw new RestoreRecoveryError('The computer has an unfinished restore whose disk is missing; recovery is required')
  await applyBinding(paths, journal.binding)
  await unlink(paths.journal)
  await syncDirectory(dirname(paths.journal))
}

/** Replace the computer's disk with a restored one, durably. The computer must be stopped. */
export async function installRestoredDisk(paths: RestorePaths, restored: RestoredDisk): Promise<void> {
  await recoverRestoredDisk(paths)
  await assertRestorable(paths, restored)
  const staged = await identity(restored.image)
  if (!staged) throw new RestoreRecoveryError('The restored disk is missing')
  const disk = await lstat(dirname(paths.disk))
  if (disk.dev !== staged.dev) throw new RestoreRecoveryError('The restored disk is not on the disk\'s filesystem')
  await writePrivateJson(paths.journal, { version: 1, staged: { path: restored.image, ...staged }, binding: restored.binding } satisfies Journal)
  await syncDirectory(dirname(paths.journal))
  await recoverRestoredDisk(paths)
}

/** A deleted computer's unfinished restore goes with it (its staged disk with its backups). */
export async function discardRestoredDisk(paths: RestorePaths): Promise<void> {
  await rm(paths.journal, { force: true })
}
