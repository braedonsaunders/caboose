import { mkdtemp, readFile, rm, stat, chmod, writeFile } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { afterEach, expect, it, vi } from 'vitest'
import { keyringSecret, prepareKeyring } from './keyring.js'

const dirs: string[] = []
afterEach(async () => { vi.unstubAllGlobals(); for (const dir of dirs.splice(0)) await rm(dir, { recursive: true, force: true }) })
async function path() { const dir = await mkdtemp(join(tmpdir(), 'caboose-keyring-')); dirs.push(dir); return join(dir, 'keyring-secret') }

it('creates a private stable per-computer credential even across concurrent first use', async () => {
  const file = await path()
  const values = await Promise.all([keyringSecret(file), keyringSecret(file), keyringSecret(file)])
  expect(new Set(values).size).toBe(1)
  expect(values[0]).toMatch(/^[a-f0-9]{64}$/)
  expect((await stat(file)).mode & 0o777).toBe(0o600)
  expect(await keyringSecret(await path())).not.toBe(values[0])
})
it('refuses invalid or public credentials without replacing them', async () => {
  const file = await path()
  await writeFile(file, 'invalid', { mode: 0o600 })
  await expect(keyringSecret(file)).rejects.toThrow('restore its protected backup')
  expect(await readFile(file, 'utf8')).toBe('invalid')
  await writeFile(file, 'a'.repeat(64)); await chmod(file, 0o644)
  await expect(keyringSecret(file)).rejects.toThrow('private file')
})
it('keeps the bootstrap credential and delivers only through the request body', async () => {
  const file = await path(), secret = 'a'.repeat(64)
  await writeFile(file, secret + '\n', { mode: 0o600 })
  const fetcher = vi.fn().mockResolvedValue(new Response('{"state":"ready"}'))
  vi.stubGlobal('fetch', fetcher)
  await prepareKeyring(file, { url: 'http://guest:14700', token: 'wake-token' })
  const [url, init] = fetcher.mock.calls[0]!
  expect(String(url)).toBe('http://guest:14700/keyring')
  expect(init.body).toBe(secret)
  expect(JSON.stringify(init.headers)).not.toContain(secret)
  expect(init.redirect).toBe('error')
})
it('returns fixed migration errors without reflecting backend text', async () => {
  vi.stubGlobal('fetch', vi.fn().mockResolvedValue(new Response('{"state":"migration-required","message":"do not echo"}', { status: 409 })))
  await expect(prepareKeyring(await path(), { url: 'http://guest', token: 'token' })).rejects.toThrow('original password')
})
it('does not expose transport errors that might contain request credentials', async () => {
  vi.stubGlobal('fetch', vi.fn().mockRejectedValue(new Error('secret request dump')))
  await expect(prepareKeyring(await path(), { url: 'http://guest', token: 'token' })).rejects.toThrow('keyring service is unavailable')
})
