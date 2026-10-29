import { createServer } from 'node:http'
import { once } from 'node:events'
import { chmod, mkdtemp, readFile, rm, writeFile } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import type { AddressInfo } from 'node:net'
import { afterEach, expect, it } from 'vitest'
import { serveParkedFiles } from './parked-files-reader.js'
import { createCabooseServer, type Controller } from './server.js'
import { SettingsStore, settingsLimits } from './settings.js'

const originalPath = process.env.PATH
afterEach(() => { process.env.PATH = originalPath })


async function fakeAppliance(path: string, acl = false, ancestorMode = 0o40755, ancestorUid = 0) {
  await writeFile(path, `#!${process.execPath}
const fs = require('node:fs');
fs.appendFileSync(__filename + '.starts', 'start\\n');
process.stdout.write(JSON.stringify({ready:true})+'\\n');
require('node:readline').createInterface({input:process.stdin}).on('line', line => {
  const {id,command,args} = JSON.parse(line);
  let result;
  if(command==='lgetxattrs') result=${acl} ? 'acl' : '';
  else if(command==='mime') result='text/plain';
  else if(command==='pread') result=Buffer.from('abcd').subarray(Number(args[1]),Number(args[1])+Number(args[2])).toString('base64');
  else if(command==='readdir') result=JSON.stringify([{ino:2,ftyp:'d',name:'.'},{ino:12,ftyp:'r',name:'note.txt'}]);
  else if(command==='lstatns') {
    const file=args[0].endsWith('/note.txt'), owner=args[0].startsWith('/home/caboose');
    result='st_ino: '+(file?12:2)+'\\nst_mode: '+(file?33188:owner?16877:${ancestorMode})+'\\nst_uid: '+(owner?1000:${ancestorUid})+'\\nst_size: '+(file?4:4096)+'\\nst_mtime_sec: 1\\nst_mtime_nsec: 0\\nst_ctime_sec: 1\\nst_ctime_nsec: 0\\n';
  } else process.exit(1);
  process.stdout.write(JSON.stringify({id,result})+'\\n');
});
`)
  await chmod(path, 0o755)
}

it('serves owner-fenced stat, list and range; unsupported paths fall back', async () => {
  const root = await mkdtemp(join(tmpdir(), 'parked-reader-'))
  const fake = join(root, 'timeout')
  await fakeAppliance(fake)
  process.env.PATH = root + ':' + originalPath
  const app = createServer((req, res) => { void serveParkedFiles({ id: 'id', homeDevice: 123, directory: root, image: '/safe/disk' }, req, res).then(served => { if (!served) { res.writeHead(409); res.end('wake') } }) })
  app.listen(0, '127.0.0.1'); await once(app, 'listening')
  try {
    const base = `http://127.0.0.1:${(app.address() as AddressInfo).port}`
    const stat = await (await fetch(base + '/v1/fs/stat?path=note.txt')).json() as { identity: string; etag: string }
    expect(stat.identity).toBe('123:12')
    const list = await (await fetch(base + '/v1/fs/list')).json() as { items: Array<{ name: string }> }
    expect(list.items.map(item => item.name)).toEqual(['note.txt'])
    const content = await fetch(base + '/v1/fs/content?path=note.txt', { headers: { range: 'bytes=1-2', 'if-match': stat.etag } })
    expect(content.status).toBe(206)
    expect(content.headers.get('content-range')).toBe('bytes 1-2/4')
    expect(await content.text()).toBe('bc')
    expect(content.headers.get('content-type')).toBe('text/plain')
    expect((await readFile(fake + '.starts', 'utf8')).trim().split('\n')).toHaveLength(3)
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
  await fakeAppliance(fake)
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
    expect((await fetch(base + '/v1/fs/stat?path=note.txt', { headers })).status).toBe(200)
    expect(wakes).toBe(0)
    expect((await fetch(base + '/v1/fs/changes', { headers })).status).toBe(200)
    expect(wakes).toBe(1)
    await fetch(base + '/v1/session/park', { method: 'POST', headers })
    expect((await fetch(base + '/v1/fs/content?path=note.txt', { method: 'PUT', headers, body: 'edit' })).status).toBe(200)
    expect(wakes).toBe(2)
  } finally {
    await app.shutdown(); upstream.closeAllConnections(); await new Promise<void>(resolve => upstream.close(() => resolve()))
    await rm(root, { recursive: true, force: true })
  }
})

it('refuses a non-owner ancestor with an access ACL despite other execute', async () => {
  const root = await mkdtemp(join(tmpdir(), 'parked-reader-acl-'))
  const fake = join(root, 'timeout')
  await fakeAppliance(fake, true)
  process.env.PATH = root + ':' + originalPath
  const app = createServer((req, res) => { void serveParkedFiles({ id: 'id', homeDevice: 123, directory: root, image: '/disk' }, req, res).then(served => { if (!served) { res.writeHead(409); res.end('wake') } }) })
  app.listen(0, '127.0.0.1'); await once(app, 'listening')
  try {
    expect((await fetch(`http://127.0.0.1:${(app.address() as AddressInfo).port}/v1/fs/stat?path=note.txt`)).status).toBe(409)
  } finally { app.closeAllConnections(); await new Promise<void>(resolve => app.close(() => resolve())); await rm(root, { recursive: true, force: true }) }
})

it.each([
  { mode: 0o40655, uid: 1000, denied: 'owner' },
  { mode: 0o40745, uid: 0, denied: 'group' },
])('falls back when the ancestor $denied class denies traversal despite other execute', async ({ mode, uid }) => {
  const root = await mkdtemp(join(tmpdir(), 'parked-reader-mode-'))
  const fake = join(root, 'timeout')
  await fakeAppliance(fake, false, mode, uid)
  process.env.PATH = root + ':' + originalPath
  const app = createServer((req, res) => { void serveParkedFiles({ id: 'id', homeDevice: 123, directory: root, image: '/disk' }, req, res).then(served => { if (!served) { res.writeHead(409); res.end('wake') } }) })
  app.listen(0, '127.0.0.1'); await once(app, 'listening')
  try {
    expect((await fetch(`http://127.0.0.1:${(app.address() as AddressInfo).port}/v1/fs/stat?path=note.txt`)).status).toBe(409)
  } finally { app.closeAllConnections(); await new Promise<void>(resolve => app.close(() => resolve())); await rm(root, { recursive: true, force: true }) }
})

it('cancels a blocked appliance when wake invalidates the parked generation', async () => {
  const root = await mkdtemp(join(tmpdir(), 'parked-reader-cancel-'))
  const fake = join(root, 'timeout')
  await writeFile(fake, `#!${process.execPath}
require('node:fs').writeFileSync(__filename+'.pid', String(process.pid));
process.stdout.write('{"ready":true}\\n');
process.stdin.resume();
`)
  await chmod(fake, 0o755)
  process.env.PATH = root + ':' + originalPath
  let current = true
  const app = createServer((req, res) => { void serveParkedFiles({ id: 'id', homeDevice: 123, directory: root, image: '/disk' }, req, res, () => current).then(served => { if (!served) { res.writeHead(409); res.end('wake') } }) })
  app.listen(0, '127.0.0.1'); await once(app, 'listening')
  const timer = setTimeout(() => { current = false }, 250)
  try {
    expect((await fetch(`http://127.0.0.1:${(app.address() as AddressInfo).port}/v1/fs/stat?path=note.txt`)).status).toBe(409)
    const pid = Number(await readFile(fake + '.pid', 'utf8'))
    expect(() => process.kill(pid, 0)).toThrow()
  } finally { clearTimeout(timer); app.closeAllConnections(); await new Promise<void>(resolve => app.close(() => resolve())); await rm(root, { recursive: true, force: true }) }
})

it('falls back without an unhandled stream error when an appliance closes its request pipe', async () => {
  const root = await mkdtemp(join(tmpdir(), 'parked-reader-pipe-'))
  const fake = join(root, 'timeout')
  await writeFile(fake, `#!${process.execPath}
require('node:fs').closeSync(0);
process.stdout.write('{"ready":true}\\n');
setInterval(() => {}, 1000);
`)
  await chmod(fake, 0o755)
  process.env.PATH = root + ':' + originalPath
  const app = createServer((req, res) => { void serveParkedFiles({ id: 'id', homeDevice: 123, directory: root, image: '/disk' }, req, res).then(served => { if (!served) { res.writeHead(409); res.end('wake') } }) })
  app.listen(0, '127.0.0.1'); await once(app, 'listening')
  try {
    expect((await fetch(`http://127.0.0.1:${(app.address() as AddressInfo).port}/v1/fs/stat?path=note.txt`)).status).toBe(409)
  } finally { app.closeAllConnections(); await new Promise<void>(resolve => app.close(() => resolve())); await rm(root, { recursive: true, force: true }) }
})
