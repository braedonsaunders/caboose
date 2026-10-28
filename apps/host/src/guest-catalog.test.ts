import { createHash } from 'node:crypto'
import { spawnSync } from 'node:child_process'
import { mkdtempSync, readFileSync, writeFileSync, mkdirSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { afterEach, expect, it } from 'vitest'

const roots: string[] = []
afterEach(() => { for (const root of roots.splice(0)) rmSync(root, { recursive: true, force: true }) })

it('verifies guest downloads before invoking apt and retains the previous release for rollback', () => {
  const root = mkdtempSync(join(tmpdir(), 'caboose-catalog-test-')); roots.push(root)
  const bin = join(root, 'bin'); mkdirSync(bin)
  const put = (name: string, body: string) => writeFileSync(join(bin, name), `#!/bin/sh\n${body}\n`, { mode: 0o755 })
  put('curl', 'while [ "$1" != "--output" ]; do shift; done; cp "$TEST_PAYLOAD" "$2"')
  put('apt-get', 'printf "%s\\n" "$*" >> "$TEST_APT_LOG"')
  put('dpkg-query', 'printf "installed\\t1.0.0-1"')
  const script = readFileSync(new URL('./guest-catalog.py', import.meta.url), 'utf8').replace("Path('/var/lib/caboose/catalog')", `Path(${JSON.stringify(join(root, 'state'))})`)
  const payload = join(root, 'payload'), log = join(root, 'apt.log')
  const env = { ...process.env, PATH: `${bin}:${process.env.PATH}`, TEST_PAYLOAD: payload, TEST_APT_LOG: log }
  const source = (version: string, contents: string) => ({ kind: 'deb', package: 'example', version, url: 'https://example.invalid/file.deb', size: Buffer.byteLength(contents), sha256: createHash('sha256').update(contents).digest('hex') })
  const execute = (action: string, src: ReturnType<typeof source>) => spawnSync('/usr/bin/python3', ['-c', script, action, JSON.stringify({ id: 'example', source: src })], { env, encoding: 'utf8' })
  writeFileSync(payload, 'first release')
  expect(execute('install', source('1.0.0', 'first release')).status).toBe(0)
  writeFileSync(payload, 'wrong contents')
  const failure = execute('update', source('2.0.0', 'second release'))
  expect(failure.status).not.toBe(0)
  expect(failure.stderr).toContain('does not match')
  expect(readFileSync(log, 'utf8').match(/install -y/g)).toHaveLength(1)
  writeFileSync(payload, 'second release')
  expect(execute('update', source('2.0.0', 'second release')).status).toBe(0)
  expect(execute('rollback', source('2.0.0', 'second release')).status).toBe(0)
  const state = JSON.parse(readFileSync(join(root, 'state/example.json'), 'utf8')) as { current: { version: string }; previous: { version: string } }
  expect(state.current.version).toBe('1.0.0')
  expect(state.previous.version).toBe('2.0.0')
  expect(readFileSync(log, 'utf8')).toContain('example-1.0.0.deb')
  expect(readFileSync(log, 'utf8')).toContain('mesa-vulkan-drivers libgl1-mesa-dri')
})
