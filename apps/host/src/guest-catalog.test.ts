import { createHash } from 'node:crypto'
import { spawn, spawnSync } from 'node:child_process'
import { mkdtempSync, readFileSync, readdirSync, writeFileSync, mkdirSync, rmSync, existsSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { afterEach, expect, it } from 'vitest'

const roots: string[] = []
afterEach(() => { for (const root of roots.splice(0)) rmSync(root, { recursive: true, force: true }) })

it('verifies a release download against its published checksum before apt, and keeps no release once installed', () => {
  const root = mkdtempSync(join(tmpdir(), 'caboose-catalog-test-')); roots.push(root)
  const bin = join(root, 'bin'); mkdirSync(bin)
  const put = (name: string, body: string) => writeFileSync(join(bin, name), `#!/bin/sh\n${body}\n`, { mode: 0o755 })
  put('curl', 'while [ "$1" != "--output" ]; do shift; done; cp "$TEST_PAYLOAD" "$2"')
  put('dpkg', 'exit 0')
  put('apt-get', 'printf "%s\\n" "$*" >> "$TEST_APT_LOG"')
  put('dpkg-query', 'printf "installed\\t1.0.0-1"')
  const state = join(root, 'state')
  const script = readFileSync(new URL('./guest-catalog.py', import.meta.url), 'utf8').replace("Path('/var/lib/caboose/catalog')", `Path(${JSON.stringify(state)})`)
  const payload = join(root, 'payload'), log = join(root, 'apt.log')
  const env = { ...process.env, PATH: `${bin}:${process.env.PATH}`, TEST_PAYLOAD: payload, TEST_APT_LOG: log }
  const source = (version: string, contents: string) => ({ kind: 'deb', package: 'example', version, url: 'https://example.invalid/file.deb', size: Buffer.byteLength(contents), sha256: createHash('sha256').update(contents).digest('hex') })
  const execute = (action: string, src: ReturnType<typeof source>) => spawnSync('/usr/bin/python3', ['-c', script, action, JSON.stringify({ id: 'example', source: src })], { env, encoding: 'utf8' })
  mkdirSync(state); writeFileSync(join(state, 'example-0.9.0.deb'), 'old cached release')
  writeFileSync(payload, 'first release')
  expect(execute('install', source('1.0.0', 'first release')).status).toBe(0)
  writeFileSync(payload, 'wrong contents')
  const failure = execute('update', source('2.0.0', 'second release'))
  expect(failure.status).not.toBe(0)
  expect(failure.stderr).toContain('does not match')
  expect(readFileSync(log, 'utf8').match(/install -y/g)).toHaveLength(1)
  writeFileSync(payload, 'second release')
  expect(execute('update', source('2.0.0', 'second release')).status).toBe(0)
  expect(readFileSync(log, 'utf8')).toContain('example-2.0.0.deb')
  expect(readFileSync(log, 'utf8')).toContain('mesa-vulkan-drivers libgl1-mesa-dri')
  expect(readdirSync(state).filter(name => name.endsWith('.deb'))).toEqual([])
  expect(spawnSync('/usr/bin/python3', ['-c', script, 'rollback', JSON.stringify({ id: 'example', source: source('2.0.0', 'second release') })], { env, encoding: 'utf8' }).stderr).toContain('Unknown operation')
})

function fixture() {
  const root = mkdtempSync(join(tmpdir(), 'caboose-catalog-feedback-')); roots.push(root)
  const bin = join(root, 'bin'), state = join(root, 'state'); mkdirSync(bin); mkdirSync(state)
  const put = (name: string, body: string) => writeFileSync(join(bin, name), `#!/usr/bin/python3\n${body}\n`, { mode: 0o755 })
  const prelude = `import os, sys, time\nfrom pathlib import Path\nr = Path(os.environ['TEST_ROOT'])\n`
  const wait = (gate: string) => `\ndeadline = time.monotonic() + 8\nwhile not (r / '${gate}').exists():\n    if time.monotonic() > deadline: sys.exit(90)\n    time.sleep(0.02)\n`
  put('dpkg-query', `print('installed\\t1.0.0-1', end='')`)
  put('dpkg', prelude + `(r / 'recovered').write_text(' '.join(sys.argv[1:]))`)
  put('apt-get', prelude + `(r / 'apt.log').open('a').write(' '.join(sys.argv[1:]) + '\\n')`)
  const env = { ...process.env, PATH: `${bin}:${process.env.PATH}`, TEST_ROOT: root }
  const script = readFileSync(new URL('./guest-catalog.py', import.meta.url), 'utf8').replace("Path('/var/lib/caboose/catalog')", `Path(${JSON.stringify(state)})`)
  const app = { id: 'example', operationId: 'test-operation', source: { kind: 'apt', packages: ['example'] } }
  const execute = (action: string, argument: unknown = app, code = script) => spawnSync('/usr/bin/python3', ['-c', code, action, JSON.stringify(argument)], { env, encoding: 'utf8' })
  const list = () => JSON.parse(execute('list', [app]).stdout).apps.example
  const read = () => JSON.parse(readFileSync(join(state, 'example.json'), 'utf8'))
  const save = (record: unknown) => writeFileSync(join(state, 'example.json'), JSON.stringify(record))
  const start = (argument: unknown = app, code = script) => {
    const child = spawn('/usr/bin/python3', ['-c', code, 'install', JSON.stringify(argument)], { env, stdio: ['ignore', 'ignore', 'pipe'] })
    let stderr = ''; child.stderr.on('data', data => { stderr += data })
    return new Promise<{ status: number | null; stderr: string }>((resolve, reject) => {
      child.on('error', reject); child.on('close', status => resolve({ status, stderr }))
    })
  }
  const release = (gate: string) => writeFileSync(join(root, gate), '')
  return { root, state, prelude, wait, put, script, app, execute, list, read, save, start, release }
}

it('reports measured download bytes and stays active without a percentage through slow package triggers', async () => {
  const f = fixture(), contents = 'release!'
  f.put('curl', f.prelude + `target = Path(sys.argv[sys.argv.index('--output') + 1])\ntarget.write_bytes(b'rele')\n(r / 'partial').touch()` + f.wait('finish-download') + `target.write_bytes(b'release!')`)
  f.put('apt-get', f.prelude + `if sys.argv[1] == 'update': sys.exit(0)\nprint('Processing triggers for shared-mime-info (2.4-5) ...', flush=True)\n(r / 'trigger').touch()` + f.wait('finish-trigger'))
  const app = { ...f.app, source: { kind: 'deb', package: 'example', version: '1.0.0', url: 'https://example.invalid/release.deb', size: contents.length, sha256: createHash('sha256').update(contents).digest('hex') } }
  const done = f.start(app)
  try {
    await expect.poll(() => existsSync(join(f.root, 'partial'))).toBe(true)
    expect(f.list()).toMatchObject({ active: true, interrupted: false, progress: { phase: 'installing', stage: 'downloading', downloadedBytes: 4, totalBytes: 8, value: 0.5 } })
    f.release('finish-download')
    await expect.poll(() => f.list().progress?.stage).toBe('configuring')
    expect(f.list()).toMatchObject({ installedVersion: '1.0.0-1', active: true, interrupted: false, progress: { phase: 'installing', value: null, message: 'Completing package setup (shared-mime-info)' } })
    expect(f.execute('install').stderr).toContain('still running')
    expect(f.read().running).toBe(true)
  } finally { f.release('finish-download'); f.release('finish-trigger'); await done }
  expect(f.list()).toMatchObject({ active: false, interrupted: false, progress: { phase: 'finished', value: null } })
}, 15000)

it('reports abandoned work as interrupted and repairs package configuration on retry even when dpkg reports installed', () => {
  const f = fixture()
  f.save({ running: true, operation: 'install', stage: 'configuring' })
  expect(f.list()).toMatchObject({ installedVersion: '1.0.0-1', active: false, interrupted: true, progress: { phase: 'failed', value: null } })
  expect(f.execute('install').status).toBe(0)
  expect(readFileSync(join(f.root, 'recovered'), 'utf8')).toBe('--configure -a')
  expect(f.list()).toMatchObject({ active: false, interrupted: false, lastError: null, progress: { phase: 'finished' } })
})

it('persists package setup failures and clears them only after a successful retry', () => {
  const f = fixture()
  f.put('apt-get', `import sys\nprint('package setup failed')\nsys.exit(42)`)
  expect(f.execute('install').status).not.toBe(0)
  expect(f.list()).toMatchObject({ active: false, interrupted: false, lastError: 'package setup failed', progress: { phase: 'failed', value: null, message: 'package setup failed' } })
  f.put('apt-get', 'pass')
  expect(f.execute('install').status).toBe(0)
  expect(f.list()).toMatchObject({ lastError: null, interrupted: false, progress: { phase: 'finished' } })
})

it('retains the guest lock while a package child survives a lost worker', async () => {
  const f = fixture()
  f.put('apt-get', f.prelude + `if sys.argv[1] == 'update': sys.exit(0)\n(r / 'child-active').touch()` + f.wait('finish-child') + `(r / 'child-finished').touch()`)
  // Simulate the guest command worker disappearing after spawning APT, without killing APT.
  const code = f.script.replace('        tail = deque(maxlen=12)', "        if command[:2] == ['apt-get', 'install']: os._exit(77)\n        tail = deque(maxlen=12)")
  try {
    expect((await f.start(f.app, code)).status).toBe(77)
    await expect.poll(() => existsSync(join(f.root, 'child-active'))).toBe(true)
    expect(f.list()).toMatchObject({ active: true, interrupted: false, progress: { phase: 'installing', value: null } })
    expect(f.execute('install').stderr).toContain('still running')
  } finally {
    f.release('finish-child')
    await expect.poll(() => existsSync(join(f.root, 'child-finished'))).toBe(true)
    await expect.poll(() => f.list().active).toBe(false)
  }
  expect(f.list()).toMatchObject({ interrupted: true, progress: { phase: 'failed' } })
}, 15000)

it('recognizes a running worker that holds only the shared catalog lock', async () => {
  const f = fixture()
  f.save({ running: true, stage: 'installing' })
  const code = f.prelude + `import fcntl\nlock = (r / 'state/install.lock').open('a')\nfcntl.flock(lock, fcntl.LOCK_EX)\n(r / 'locked').touch()` + f.wait('release-lock')
  const done = f.start(f.app, code)
  try {
    await expect.poll(() => existsSync(join(f.root, 'locked'))).toBe(true)
    expect(f.list()).toMatchObject({ active: true, interrupted: false, progress: { phase: 'installing', value: null } })
  } finally { f.release('release-lock'); await done }
  expect(f.list()).toMatchObject({ active: false, interrupted: true, progress: { phase: 'failed' } })
}, 15000)
