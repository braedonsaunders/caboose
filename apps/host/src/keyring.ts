import { randomBytes } from 'node:crypto'
import { constants } from 'node:fs'
import { link, mkdir, open, unlink } from 'node:fs/promises'
import { dirname } from 'node:path'
import type { FileService } from './fs-proxy.js'

/** Persistent host custody. Never regenerate or replace an existing credential. */
export async function keyringSecret(path: string): Promise<string> {
  await mkdir(dirname(path), { recursive: true })
  const temporary = `${path}.${randomBytes(12).toString('hex')}.tmp`
  try {
    const created = await open(temporary, 'wx', 0o600)
    try { await created.writeFile(randomBytes(32).toString('hex')); await created.sync() }
    finally { await created.close() }
    await link(temporary, path).catch(error => { if (error.code !== 'EEXIST') throw error })
  } finally { await unlink(temporary).catch(() => {}) }
  const file = await open(path, constants.O_RDONLY | constants.O_NOFOLLOW)
  try {
    const info = await file.stat()
    if (!info.isFile() || (info.mode & 0o077) || (process.getuid && info.uid !== process.getuid())) {
      throw new Error('The computer keyring credential must be a private file owned by the host user')
    }
    if (info.size < 64 || info.size > 65) throw new Error('The saved computer keyring credential is invalid; restore its protected backup')
    const secret = (await file.readFile('utf8')).replace(/\n$/, '')
    if (!/^[a-f0-9]{64}$/.test(secret)) throw new Error('The saved computer keyring credential is invalid; restore its protected backup')
    // Existing bootstrap credentials receive the same durability guarantee.
    await file.sync()
    const directory = await open(dirname(path), constants.O_RDONLY)
    try { await directory.sync() } finally { await directory.close() }
    return secret
  } finally { await file.close() }
}

/** Private Files connection carries the credential as a bounded body, never as argv. */
export async function prepareKeyring(path: string, service: FileService): Promise<void> {
  const secret = await keyringSecret(path)
  let response: Response
  try {
    response = await fetch(new URL('/keyring', service.url), {
      method: 'POST', headers: { authorization: `Bearer ${service.token}`, 'content-type': 'application/octet-stream' },
      body: secret, redirect: 'error', signal: AbortSignal.timeout(50_000),
    })
  } catch { throw new Error('The computer keyring service is unavailable') }
  // Never relay untrusted backend text or request headers into errors/logs.
  let result: { state?: unknown } | null = null
  const reader = response.body?.getReader()
  if (reader) {
    let body = ''
    try {
      for (;;) {
        const part = await reader.read()
        if (part.done) break
        body += new TextDecoder().decode(part.value)
        if (body.length > 256) { await reader.cancel(); break }
      }
      if (body.length <= 256) result = JSON.parse(body)
    } catch { /* Report the fixed service error below. */ }
    finally { reader.releaseLock() }
  }
  if (response.ok && result?.state === 'ready') return
  if (result?.state === 'migration-required') throw new Error('The existing keyring requires its original password and an explicit credential migration')
  throw new Error('The computer keyring service is unavailable')
}
