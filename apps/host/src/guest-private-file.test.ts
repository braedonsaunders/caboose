import { spawn } from 'node:child_process'
import { mkdir, mkdtemp, readFile, rm, stat, writeFile } from 'node:fs/promises'
import { createServer } from 'node:net'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { afterEach, expect, it } from 'vitest'
import { replaceGuestFile } from './guest-private-file.js'

const cleanup: Array<() => Promise<void>> = []
afterEach(async () => { for (const step of cleanup.splice(0).reverse()) await step() })

async function freePort(): Promise<number> {
  const server = createServer()
  await new Promise<void>(resolve => server.listen(0, '127.0.0.1', resolve))
  const port = (server.address() as { port: number }).port
  await new Promise(resolve => server.close(resolve))
  return port
}

/** The computer's real file service (guest/files/caboose-files.py), on a temporary home. */
async function fileService() {
  const root = await mkdtemp(join(tmpdir(), 'caboose-private-file-'))
  cleanup.push(() => rm(root, { recursive: true, force: true }))
  const home = join(root, 'home'), token = 'files-token-0123456789'
  await mkdir(join(home, '.local/state/caboose'), { recursive: true })
  await writeFile(join(root, 'token'), token)
  const port = await freePort()
  const child = spawn('python3', [new URL('../../../guest/files/caboose-files.py', import.meta.url).pathname], {
    env: { ...process.env, CABOOSE_FILES_ROOT: home, CABOOSE_FILES_TOKEN_FILE: join(root, 'token'), CABOOSE_FILES_PORT: String(port) }, stdio: 'ignore',
  })
  cleanup.push(async () => { child.kill(); await new Promise(resolve => child.once('exit', resolve)) })
  const url = `http://127.0.0.1:${port}`
  for (let i = 0; i < 100; i++) {
    if (await fetch(`${url}/stat?path=`, { headers: { authorization: `Bearer ${token}` } }).then(r => r.ok, () => false)) break
    await new Promise(resolve => setTimeout(resolve, 50))
  }
  return { service: { url, token }, home }
}

// The real service watches files with inotify, so these run on Linux (the host image, CI, Docker).
const linux = it.skipIf(process.platform !== 'linux')

linux('creates the file privately, then replaces it again and again through the real file service', async () => {
  const { service, home } = await fileService()
  const path = '.local/state/caboose/mcp-library.json'
  await replaceGuestFile(service, path, Buffer.from('{"token":"first"}'))
  await replaceGuestFile(service, path, Buffer.from('{"token":"second"}'))
  await replaceGuestFile(service, path, Buffer.from('{"token":"third"}'))
  expect(await readFile(join(home, path), 'utf8')).toBe('{"token":"third"}')
  expect((await stat(join(home, path))).mode & 0o777).toBe(0o600)
})

linux('tries again when the file changes between checking it and replacing it', async () => {
  const { service, home } = await fileService()
  const path = '.local/state/caboose/mcp-library.json'
  await replaceGuestFile(service, path, Buffer.from('one'))
  let raced = false
  const racing = async (url: string, init?: RequestInit) => {
    if (!raced && init?.method === 'PUT') {
      raced = true
      // Someone else replaces the file after it was checked.
      await new Promise(resolve => setTimeout(resolve, 20))
      await writeFile(join(home, path), 'someone else')
    }
    return fetch(url, init)
  }
  await replaceGuestFile(service, path, Buffer.from('two'), racing)
  expect(raced).toBe(true)
  expect(await readFile(join(home, path), 'utf8')).toBe('two')
})

it('states the version it replaces, creates only when absent, and gives up after repeated races', async () => {
  const sent: Array<{ method: string; headers: Record<string, string> }> = []
  let version: string | null = null, races = 0
  const fake = async (url: string, init: RequestInit = {}) => {
    const headers = Object.fromEntries(Object.entries((init.headers ?? {}) as Record<string, string>).map(([k, v]) => [k.toLowerCase(), v]))
    sent.push({ method: init.method ?? 'GET', headers })
    if (url.includes('/stat')) return version ? new Response(JSON.stringify({ etag: version })) : new Response('{}', { status: 404 })
    if (races-- > 0) { version = `v${Math.random()}`; return new Response('{}', { status: 412 }) }
    if (version ? headers['if-match'] !== version : headers['if-none-match'] !== '*') return new Response('{}', { status: 428 })
    version = `v${sent.length}`
    return new Response('{}', { status: version ? 200 : 201 })
  }
  const service = { url: 'http://computer', token: 't' }
  await replaceGuestFile(service, 'a.json', Buffer.from('1'), fake)
  expect(sent[1]!.headers['if-none-match']).toBe('*')
  await replaceGuestFile(service, 'a.json', Buffer.from('2'), fake)
  expect(sent[3]!.headers['if-match']).toBe('v2')
  races = 1
  await replaceGuestFile(service, 'a.json', Buffer.from('3'), fake)
  races = 10
  await expect(replaceGuestFile(service, 'a.json', Buffer.from('4'), fake)).rejects.toThrow('kept changing')
})
