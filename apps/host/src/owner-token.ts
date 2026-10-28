import { randomBytes } from 'node:crypto'
import { mkdir, readFile, writeFile } from 'node:fs/promises'
import { dirname } from 'node:path'

/**
 * The owner token when `CABOOSE_OWNER_TOKEN` is not set: generated once and kept in the
 * host's state directory (mode 0600), so a new host needs no environment file. Returns the
 * token and whether this call created it.
 */
export async function ownerToken(path: string): Promise<{ token: string; created: boolean }> {
  try {
    const token = (await readFile(path, 'utf8')).trim()
    if (token.length >= 32) return { token, created: false }
    throw new Error(`${path} holds no usable owner token; remove it to generate a new one`)
  } catch (error) {
    if ((error as NodeJS.ErrnoException).code !== 'ENOENT') throw error
  }
  const token = randomBytes(32).toString('hex')
  await mkdir(dirname(path), { recursive: true })
  // `wx` refuses to replace a token another process wrote first.
  await writeFile(path, `${token}\n`, { mode: 0o600, flag: 'wx' }).catch(async error => {
    if ((error as NodeJS.ErrnoException).code === 'EEXIST') return
    throw error
  })
  return { token: (await readFile(path, 'utf8')).trim(), created: true }
}
