import { createServer } from 'node:http'
import { once } from 'node:events'
import { chmod, mkdtemp, rm, writeFile } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import type { AddressInfo } from 'node:net'
import { afterEach, expect, it } from 'vitest'
import { serveParkedFiles } from './parked-files-reader.js'
import { createCabooseServer, type Controller } from './server.js'
import { SettingsStore, settingsLimits } from './settings.js'

const originalPath = process.env.PATH
afterEach(() => { process.env.PATH = originalPath })

it('serves owner-fenced stat, list and range; unsupported paths fall back', async () => {
  const root = await mkdtemp(join(tmpdir(), 'parked-reader-'))
  const fake = join(root, 'timeout')
  const script = `#!/bin/sh
case "$*" in
  *" lgetxattrs "*) exit 0 ;;
  *" download-offset "*) printf bc ;;
  *" readdir "*) printf '[0] = {\\n  ino: 2\\n  ftyp: d\\n  name: .\\n}\\n[1] = {\\n  ino: 12\\n  ftyp: r\\n  name: note\\n}\\n' ;;
  *" lstatns /home/caboose/note"*) printf 'st_ino: 12\\nst_mode: 33188\\nst_uid: 1000\\nst_size: 4\\nst_mtime_sec: 1\\nst_mtime_nsec: 0\\nst_ctime_sec: 1\\nst_ctime_nsec: 0\\n' ;;
  *" lstatns /home/caboose"*) printf 'st_ino: 2\\nst_mode: 16877\\nst_uid: 1000\\nst_size: 4096\\nst_mtime_sec: 1\\nst_mtime_nsec: 0\\nst_ctime_sec: 1\\nst_ctime_nsec: 0\\n' ;;
  *" lstatns /"*) printf 'st_ino: 2\\nst_mode: 16877\\nst_uid: 0\\nst_size: 4096\\nst_mtime_sec: 1\\nst_mtime_nsec: 0\\nst_ctime_sec: 1\\nst_ctime_nsec: 0\\n' ;;
  *" lstatns /home"*) printf 'st_ino: 2\\nst_mode: 16877\\nst_uid: 0\\nst_size: 4096\\nst_mtime_sec: 1\\nst_mtime_nsec: 0\\nst_ctime_sec: 1\\nst_ctime_nsec: 0\\n' ;;
  *) exit 1 ;;
esac
`
  await writeFile(fake, script); await chmod(fake, 0o755)
  process.env.PATH = root + ':' + originalPath
  const app = createServer((req, res) => { void serveParkedFiles({ id: 'id', homeDevice: 123, directory: root, image: '/safe/disk' }, req, res).then(served => { if (!served) { res.writeHead(409); res.end('wake') } }) })
  app.listen(0, '127.0.0.1'); await once(app, 'listening')
  try {
    const base = `http://127.0.0.1:${(app.address() as AddressInfo).port}`
    const stat = await (await fetch(base + '/v1/fs/stat?path=note')).json() as { identity: string; etag: string }
    expect(stat.identity).toBe('123:12')
    const list = await (await fetch(base + '/v1/fs/list')).json() as { items: Array<{ name: string }> }
    expect(list.items.map(item => item.name)).toEqual(['note'])
    const content = await fetch(base + '/v1/fs/content?path=note', { headers: { range: 'bytes=1-2', 'if-match': stat.etag } })
    expect(content.status).toBe(206)
    expect(content.headers.get('content-range')).toBe('bytes 1-2/4')
    expect(await content.text()).toBe('bc')
    expect((await fetch(base + '/v1/fs/content?path=../etc')).status).toBe(409)
    expect((await fetch(base + '/v1/fs/changes')).status).toBe(409)
  } finally {
    app.closeAllConnections(); await new Promise<void>(resolve => app.close(() => resolve()))
    await rm(root, { recursive: true, force: true })
  }
})

it('uses a parked view for a safe read and wakes for unsupported reads and mutations', async () => {
  const root = await mkdtemp(join(tmpdir(), 'parked-reader-route-'))
  const fake = join(root, 'timeout')
  await writeFile(fake, `#!/bin/sh
case "$*" in
  *" lgetxattrs "*) exit 0 ;;
  *" lstatns /home/caboose/note"*) printf 'st_ino: 12\\nst_mode: 33188\\nst_uid: 1000\\nst_size: 4\\nst_mtime_sec: 1\\nst_mtime_nsec: 0\\nst_ctime_sec: 1\\nst_ctime_nsec: 0\\n' ;;
  *" lstatns /home/caboose"*) printf 'st_ino: 2\\nst_mode: 16877\\nst_uid: 1000\\nst_size: 4096\\nst_mtime_sec: 1\\nst_mtime_nsec: 0\\nst_ctime_sec: 1\\nst_ctime_nsec: 0\\n' ;;
  *" lstatns /"*) printf 'st_ino: 2\\nst_mode: 16877\\nst_uid: 0\\nst_size: 4096\\nst_mtime_sec: 1\\nst_mtime_nsec: 0\\nst_ctime_sec: 1\\nst_ctime_nsec: 0\\n' ;;
  *" lstatns /home"*) printf 'st_ino: 2\\nst_mode: 16877\\nst_uid: 0\\nst_size: 4096\\nst_mtime_sec: 1\\nst_mtime_nsec: 0\\nst_ctime_sec: 1\\nst_ctime_nsec: 0\\n' ;;
  *) exit 1 ;;
esac
`); await chmod(fake, 0o755)
  process.env.PATH = root + ':' + originalPath
  const upstream = createServer((req, res) => { req.resume(); req.on('end', () => res.end('{}')) })
  upstream.listen(0, '127.0.0.1'); await once(upstream, 'listening')
  let wakes = 0
  const controller: Controller = {
    wake: async () => { wakes++; return { state: 'running', display: { path: '/v1/display', token: '', protocol: 'caboose-display' }, computer: { name: 'Caboose', image: 'Debian', memoryMb: 2048, vcpus: 2 } } },
    park: async () => {}, stats: () => ({}), apps: async () => [], launch: async () => {}, displayUrl: '', agentDisplayUrl: '', ensureAgentSeat: async () => {}, guest: () => undefined, activeResources: () => null, hasSavedState: () => true,
    parkedFilesView: async () => ({ id: 'id', homeDevice: 123, directory: root, image: '/safe/disk' }),
    fileService: () => ({ url: `http://127.0.0.1:${(upstream.address() as AddressInfo).port}`, token: 'private' }),
  }
  const settings = new SettingsStore({ name: 'Caboose', memoryMb: 2048, vcpus: 2, idleMs: 60_000, defaultAgent: null }, settingsLimits(), { load: async () => undefined, save: async () => {} })
  const app = createCabooseServer({ token: 'owner', settings, controller })
  app.server.listen(0, '127.0.0.1'); await once(app.server, 'listening')
  try {
    const base = `http://127.0.0.1:${(app.server.address() as AddressInfo).port}`
    const headers = { authorization: 'Bearer owner' }
    expect((await fetch(base + '/v1/fs/stat?path=note', { headers })).status).toBe(200)
    expect(wakes).toBe(0)
    expect((await fetch(base + '/v1/fs/changes', { headers })).status).toBe(200)
    expect(wakes).toBe(1)
    await fetch(base + '/v1/session/park', { method: 'POST', headers })
    expect((await fetch(base + '/v1/fs/content?path=note', { method: 'PUT', headers, body: 'edit' })).status).toBe(200)
    expect(wakes).toBe(2)
  } finally {
    await app.shutdown(); upstream.closeAllConnections(); await new Promise<void>(resolve => upstream.close(() => resolve()))
    await rm(root, { recursive: true, force: true })
  }
})

it('refuses a non-owner ancestor with an access ACL despite other execute', async () => {
  const root = await mkdtemp(join(tmpdir(), 'parked-reader-acl-'))
  const fake = join(root, 'timeout')
  await writeFile(fake, `#!/bin/sh
case "$*" in
  *" lstatns /"*) printf 'st_ino: 2\\nst_mode: 16877\\nst_uid: 0\\nst_size: 4096\\nst_mtime_sec: 1\\nst_mtime_nsec: 0\\nst_ctime_sec: 1\\nst_ctime_nsec: 0\\n' ;;
  *" lgetxattrs /"*) printf '[0] = {\\n  attrname: system.posix_acl_access\\n}\\n' ;;
  *) exit 1 ;;
esac
`); await chmod(fake, 0o755)
  process.env.PATH = root + ':' + originalPath
  const app = createServer((req, res) => { void serveParkedFiles({ id: 'id', homeDevice: 123, directory: root, image: '/disk' }, req, res).then(served => { if (!served) { res.writeHead(409); res.end('wake') } }) })
  app.listen(0, '127.0.0.1'); await once(app, 'listening')
  try {
    expect((await fetch(`http://127.0.0.1:${(app.address() as AddressInfo).port}/v1/fs/stat?path=note`)).status).toBe(409)
  } finally { app.closeAllConnections(); await new Promise<void>(resolve => app.close(() => resolve())); await rm(root, { recursive: true, force: true }) }
})
