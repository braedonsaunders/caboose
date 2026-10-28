import { afterEach, describe, expect, it } from 'vitest'
import { mkdtempSync, mkdirSync, rmSync, symlinkSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join, resolve } from 'node:path'
import { spawnSync } from 'node:child_process'

const dirs: string[] = []
afterEach(() => { for (const dir of dirs.splice(0)) rmSync(dir, { recursive: true, force: true }) })
function guest() {
  const dir = mkdtempSync(join(tmpdir(), 'caboose-phone-test-')); dirs.push(dir)
  const bin = join(dir, 'bin'); mkdirSync(bin)
  const executable = resolve('../../guest/phone/caboose-phone')
  for (const name of ['caboose-phone', 'caboose-open', 'caboose-share']) symlinkSync(executable, join(bin, name))
  function run(name: string, ...args: string[]) {
    return spawnSync(join(bin, name), args, { encoding: 'utf8', env: { ...process.env, HOME: dir } })
  }
  return { dir, run }
}

describe('guest phone commands', () => {
  it('queues only supported URLs, stages a snapshot, and drains in order', () => {
    const { dir, run } = guest()
    expect(run('caboose-open', 'file:///etc/passwd').status).toBe(1)
    expect(run('caboose-open', 'tel:123').status).toBe(0)
    const source = join(dir, 'photo.txt'); writeFileSync(source, 'hello')
    expect(run('caboose-share', source).status).toBe(0)
    writeFileSync(source, 'changed')
    const events = JSON.parse(run('caboose-phone', 'drain').stdout)
    expect(events.map((e: { type: string }) => e.type)).toEqual(['phone.open', 'phone.share'])
    expect(events[1]).toMatchObject({ name: 'photo.txt', size: 5, contentType: 'text/plain' })
    expect(run('caboose-phone', 'info', events[1].id).stdout.trim()).toBe('5')
    expect(run('caboose-phone', 'read', events[1].id, '0', '5').stdout).toBe('aGVsbG8=')
    expect(JSON.parse(run('caboose-phone', 'drain').stdout)).toEqual([])
  })
  it('rejects non-PDF print jobs and invalid file IDs', () => {
    const { dir, run } = guest()
    const source = join(dir, 'bad.pdf'); writeFileSync(source, 'not pdf')
    expect(run('caboose-phone', 'print', source).status).toBe(1)
    expect(run('caboose-phone', 'read', '../secret', '0', '5').status).toBe(1)
    expect(JSON.parse(run('caboose-phone', 'drain').stdout)).toEqual([])
  })
})
