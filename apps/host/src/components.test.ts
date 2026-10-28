import { describe, expect, it } from 'vitest'
import { execFileSync } from 'node:child_process'
import { fileURLToPath } from 'node:url'
import { needsUpgrade, readBundle, upgradeComponents, type UpgradeStatus } from './components.js'
import type { AgentGuest } from './agents.js'

const bundle = { version: 'a'.repeat(64), files: [{ name: 'components/install.sh', data: Buffer.alloc(50000, 42) }] }
function guest(installed: string, failInstall = false) {
  const calls: { command: string; args: string[] }[] = []
  const runner: AgentGuest = { run: async (command, args) => {
    calls.push({ command, args })
    if (command === '/bin/mktemp') return '/tmp/caboose-components.ABCD1234\n'
    if (command === '/bin/bash') { if (failInstall) throw new Error('apt failed'); installed = bundle.version }
    if (command === '/bin/cat') return installed + '\n'
    if (command === '/bin/sh' && args[1]?.startsWith('cat ')) return installed
    return ''
  } }
  return { runner, calls }
}

describe('guest components', () => {
  it('uses the same content hash as the image builder', async () => {
    const path = fileURLToPath(new URL('../../../guest/', import.meta.url))
    const version = execFileSync('python3', [`${path}/components/version.py`, path], { encoding: 'utf8' }).trim()
    expect((await readBundle(path)).version).toBe(version)
    expect(needsUpgrade(version + '\n', version)).toBe(false)
    expect(needsUpgrade('', version)).toBe(true)
  })
  it('stages bounded chunks as root and skips all writes on the next check', async () => {
    const { runner, calls } = guest('old')
    const events: UpgradeStatus[] = []
    await upgradeComponents(runner, 'vm', e => events.push(e), bundle)
    expect(events.map(e => e.state)).toEqual(['checking', 'updating', 'succeeded'])
    expect(calls.some(c => c.command === '/bin/bash' && c.args[1] === 'vm')).toBe(true)
    const chunks = calls.filter(c => c.command === '/bin/sh' && c.args[1]?.includes('base64 -d'))
    expect(chunks).toHaveLength(2)
    expect(chunks.every(c => (c.args.at(-1)?.length ?? 0) <= 48 * 1024)).toBe(true)
    expect(calls.at(-2)?.command).toBe('/bin/cat')
    expect(calls.at(-1)?.command).toBe('/bin/rm')
    calls.length = 0
    await upgradeComponents(runner, 'vm', () => {}, bundle)
    expect(calls).toHaveLength(2)
    expect(calls[1]?.args[1]).toContain("systemctl start caboose-files.service")
  })
  it('reports failure, cleans staging and retries on the next attempt', async () => {
    const { runner, calls } = guest('', true)
    const events: UpgradeStatus[] = []
    await upgradeComponents(runner, 'container', e => events.push(e), bundle)
    expect(events.at(-1)).toMatchObject({ state: 'failed', message: 'apt failed' })
    expect(calls.at(-1)?.command).toBe('/bin/rm')
    await upgradeComponents(runner, 'container', () => {}, bundle)
    expect(calls.filter(c => c.command === '/bin/bash')).toHaveLength(2)
  })
})
