// caboose-apps over stdio against a temporary home, with the real caboose-app for every
// tool but app_open's window (a stand-in runtime records the launch instead).
//
//     node --test guest/apps/apps-mcp.test.mjs
import { spawn } from 'node:child_process'
import { chmod, mkdir, mkdtemp, readFile, realpath, rm, writeFile } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { createInterface } from 'node:readline'
import { after, before, describe, it } from 'node:test'
import assert from 'node:assert/strict'

const SERVER = new URL('./apps-mcp.mjs', import.meta.url).pathname
const RUNTIME = new URL('./caboose-app', import.meta.url).pathname

let root
before(async () => { root = await realpath(await mkdtemp(join(tmpdir(), 'caboose-apps-mcp-'))) })
after(() => rm(root, { recursive: true, force: true }))

async function server(runtime = RUNTIME) {
  const home = join(root, `home-${Math.random().toString(16).slice(2)}`)
  await mkdir(home)
  const child = spawn(process.execPath, [SERVER], {
    env: { ...process.env, HOME: home, CABOOSE_APP_RUNTIME: runtime, CABOOSE_AGENT_DISPLAY: ':101', CABOOSE_DISPLAY_CONTROL: join(root, 'synthetic-control.sock') },
    stdio: ['pipe', 'pipe', 'inherit'],
  })
  const waiting = new Map()
  createInterface({ input: child.stdout }).on('line', line => {
    const message = JSON.parse(line)
    waiting.get(message.id)?.(message)
    waiting.delete(message.id)
  })
  let next = 1
  const request = (method, params) => new Promise(resolve => {
    const id = next++
    waiting.set(id, resolve)
    child.stdin.write(JSON.stringify({ jsonrpc: '2.0', id, method, params }) + '\n')
  })
  const call = async (name, args = {}) => (await request('tools/call', { name, arguments: args })).result
  const app = async (id, manifest, files = { 'index.html': '<!doctype html><title>x</title>' }) => {
    const dir = join(home, 'Apps', id)
    await mkdir(dir, { recursive: true })
    await writeFile(join(dir, 'app.json'), JSON.stringify(manifest))
    for (const [name, data] of Object.entries(files)) await writeFile(join(dir, name), data)
  }
  after(() => child.kill())
  return { home, request, call, app }
}

describe('caboose-apps', () => {
  it('initializes and lists its tools', async () => {
    const { request } = await server()
    const init = await request('initialize', { protocolVersion: '2025-06-18' })
    assert.equal(init.result.serverInfo.name, 'caboose-apps')
    const { result } = await request('tools/list', {})
    assert.deepEqual(result.tools.map(tool => tool.name), ['app_guide', 'app_publish', 'app_list', 'app_open', 'app_remove'])
  })

  it('returns the guide', async () => {
    const { call } = await server()
    const result = await call('app_guide')
    assert.match(result.content[0].text, /^# Making a Caboose app/)
    assert.match(result.content[0].text, /window\.caboose/)
  })

  it('publishes a valid app into the Apps screen', async () => {
    const { call, app, home } = await server()
    await app('weather', { name: 'Weather', capabilities: ['exec'] })
    const result = await call('app_publish', { id: 'weather' })
    assert.equal(result.isError, undefined)
    const published = JSON.parse(result.content[0].text)
    assert.deepEqual({ ...published, warnings: [] }, { published: true, id: 'weather', name: 'Weather', capabilities: ['exec'], warnings: [] })
    assert.equal(published.warnings.length, 1)
    assert.match(published.warnings[0], /viewport/)
    const entry = await readFile(join(home, '.local/share/applications/caboose.app.weather.desktop'), 'utf8')
    assert.match(entry, /^Exec=\/usr\/local\/bin\/caboose-app run weather$/m)
    const listed = JSON.parse((await call('app_list')).content[0].text)
    assert.equal(listed.length, 1)
    assert.equal(listed[0].published, true)
    await app('mobile', { name: 'Mobile' }, { 'index.html': '<meta name="viewport" content="width=device-width, initial-scale=1">' })
    assert.deepEqual(JSON.parse((await call('app_publish', { id: 'mobile' })).content[0].text).warnings, [])
  })

  it('says what to fix in an invalid app', async () => {
    const { call, app } = await server()
    await app('broken', { title: 'x' })
    const result = await call('app_publish', { id: 'broken' })
    assert.equal(result.isError, true)
    assert.match(result.content[0].text, /broken is not published:\n- Unknown field "title"/)
    assert.match(result.content[0].text, /- name is required/)
  })

  it('refuses ids that are not app ids', async () => {
    const { call } = await server()
    for (const id of ['../x', 'Upper', '', 7]) {
      const result = await call('app_publish', { id })
      assert.equal(result.isError, true)
      assert.match(result.content[0].text, /id must be a lowercase letter/)
    }
  })

  it('opens a valid app on the agent display', async () => {
    const log = join(root, 'launch.log')
    const stand = join(root, 'stand-in-runtime')
    await writeFile(stand, `#!/bin/sh\nif [ "$1" = run ]; then printf '%s %s %s %s\\n' "$1" "$2" "$DISPLAY" "$HOME" > "${log}"; exit 0; fi\nexec "${RUNTIME}" "$@"\n`)
    await chmod(stand, 0o755)
    const { call, app, home } = await server(stand)
    await app('clock', { name: 'Clock' })
    const result = await call('app_open', { id: 'clock' })
    assert.match(result.content[0].text, /^Opened Clock on your display/)
    for (let i = 0; i < 50; i++) {
      if (await readFile(log, 'utf8').catch(() => '')) break
      await new Promise(resolve => setTimeout(resolve, 20))
    }
    assert.equal(await readFile(log, 'utf8'), `run clock :101 ${home}\n`)
    const missing = await call('app_open', { id: 'nothing' })
    assert.equal(missing.isError, true)
  })

  it('removes and purges', async () => {
    const { call, app, home } = await server()
    await app('temp', { name: 'Temp' })
    await call('app_publish', { id: 'temp' })
    const removed = JSON.parse((await call('app_remove', { id: 'temp' })).content[0].text)
    assert.deepEqual(removed.removed, [join(home, '.local/share/applications/caboose.app.temp.desktop')])
    await call('app_remove', { id: 'temp', purge: true })
    assert.deepEqual(JSON.parse((await call('app_list')).content[0].text), [])
  })
})
