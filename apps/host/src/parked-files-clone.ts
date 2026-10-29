import { constants } from 'node:fs'
import { copyFile, lstat, mkdtemp, open, rm } from 'node:fs/promises'
import { join } from 'node:path'

/** Stage a reflink-only copy while the source VM is paused. The returned image is
 * not authoritative until the caller binds it to a successfully parked snapshot. */
export async function stageParkedDisk(source: string, parent: string, maxBytes: number): Promise<{ directory: string; image: string }> {
  if (!Number.isSafeInteger(maxBytes) || maxBytes < 1) throw new Error('Invalid parked Files disk limit')
  const before = await lstat(source)
  if (!before.isFile() || before.isSymbolicLink() || before.size > maxBytes) throw new Error('Unsupported parked Files source disk')
  const directory = await mkdtemp(join(parent, '.parked-files-'))
  const image = join(directory, 'disk.raw')
  try {
    await copyFile(source, image, constants.COPYFILE_FICLONE_FORCE | constants.COPYFILE_EXCL)
    const after = await lstat(source)
    const staged = await lstat(image)
    if (!after.isFile() || after.dev !== before.dev || after.ino !== before.ino || after.size !== before.size || after.mtimeMs !== before.mtimeMs || !staged.isFile() || staged.size !== before.size) throw new Error('Parked Files source disk changed during clone')
    const file = await open(image, constants.O_RDONLY | constants.O_NOFOLLOW)
    try { await file.sync() } finally { await file.close() }
    const dir = await open(directory, 'r')
    try { await dir.sync() } finally { await dir.close() }
    return { directory, image }
  } catch (error) {
    await rm(directory, { recursive: true, force: true })
    throw error
  }
}
