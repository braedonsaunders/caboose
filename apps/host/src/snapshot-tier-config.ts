import { constants } from 'node:fs'
import { open } from 'node:fs/promises'

/** A tier key is supplied explicitly so a lost key is never silently replaced. */
export async function snapshotTierKey(env: NodeJS.ProcessEnv, runtime: 'microvm' | 'container', platform: NodeJS.Platform = process.platform): Promise<Uint8Array | undefined> {
  const enabled = env.CABOOSE_SNAPSHOT_TIER ?? 'off'
  if (enabled === 'off') return undefined
  if (enabled !== 'on') throw new Error('CABOOSE_SNAPSHOT_TIER must be on or off')
  if (runtime !== 'microvm' || platform !== 'linux') throw new Error('Snapshot tiering requires Linux microVMs')
  const path = env.CABOOSE_SNAPSHOT_KEY_FILE
  if (!path || !path.startsWith('/')) throw new Error('CABOOSE_SNAPSHOT_KEY_FILE must be an absolute path')
  const file = await open(path, constants.O_RDONLY | constants.O_NOFOLLOW)
  try {
    const stat = await file.stat()
    if (!stat.isFile() || (stat.mode & 0o077) !== 0 || (process.getuid && stat.uid !== process.getuid()) || stat.size > 256) {
      throw new Error('Snapshot key file must be a private regular file owned by the host user')
    }
    const value = (await file.readFile('utf8')).trim()
    if (!/^[a-f0-9]{64}$/.test(value)) throw new Error('Snapshot key file must contain 32 bytes as lowercase hexadecimal')
    return Buffer.from(value, 'hex')
  } finally { await file.close() }
}
