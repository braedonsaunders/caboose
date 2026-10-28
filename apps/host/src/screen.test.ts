import { execFile } from 'node:child_process'
import { mkdtemp } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { promisify } from 'node:util'
import { describe, expect, it } from 'vitest'
import { ON_DISPLAY, normalizeKey, screenAct, screenElements, screenKeys, screenType } from './screen.js'

describe('screen', () => {
  it('reports the exit status and keeps stderr out of a successful answer', async () => {
    const scratch = await mkdtemp(join(tmpdir(), 'caboose-screen-'))
    const run = async (...command: string[]) => (await promisify(execFile)('/bin/sh', ['-c', ON_DISPLAY, 'sh', ':100', ...command], { env: { ...process.env, TMPDIR: scratch } })).stdout
    expect(await run('/bin/sh', '-c', 'echo warning >&2; echo "{\\"display\\":\\"$DISPLAY\\"}"')).toBe('0\n{"display":":100"}')
    expect(await run('/bin/sh', '-c', 'echo \'{"ok":false}\'; echo gone >&2; exit 3')).toBe('3\n{"ok":false} gone')
  })

  it('runs as caboose on the owner display and passes through why a window is empty', async () => {
    const runs: string[][] = []
    const guest = { ownerEnv: ['DISPLAY=:110'], run: async (command: string, args: string[]) => { runs.push([command, ...args]); return '0\n{"window":{"title":"","app":""},"elements":[],"note":"No window is open on this display."}' } }
    expect(await screenElements(guest)).toEqual({ window: { title: '', app: '' }, elements: [], note: 'No window is open on this display.' })
    expect(runs[0]!.slice(0, 4)).toEqual(['/usr/sbin/runuser', '-u', 'caboose', '--'])
    expect(runs[0]!.slice(4)).toEqual(['/usr/bin/env', 'DISPLAY=:110', '/bin/sh', '-c', ON_DISPLAY, 'sh', ':110', '/usr/bin/python3', '/opt/caboose/a11y.py', 'elements', '--display', ':110'])
    await screenType(guest, { text: '-rf is just text' })
    expect(runs[1]!.slice(-4)).toEqual(['/opt/caboose/seat.py', 'type', '--', '-rf is just text'])
    await screenKeys(guest, { keys: 'ctrl+shift+T Enter' })
    expect(runs[2]!.slice(-5)).toEqual(['/opt/caboose/seat.py', 'key', '--', 'ctrl+shift+t', 'Return'])
  })

  it('uses the X display and environment Caboose Display reports', async () => {
    const runs: string[][] = []
    const env = ['WAYLAND_DISPLAY=wayland-caboose-0', 'DISPLAY=:110', 'XAUTHORITY=/run/user/1000/caboose-display/Xauthority']
    const guest = { ownerEnv: env, run: async (command: string, args: string[]) => { runs.push([command, ...args]); return '0\n{"ok":true}' } }
    await screenAct(guest, { element: '0.1', action: 'press' })
    expect(runs[0]!.slice(4, 8)).toEqual(['/usr/bin/env', ...env])
    expect(runs[0]!.slice(11, 17)).toEqual(['sh', ':110', '/usr/bin/python3', '/opt/caboose/a11y.py', 'act', '--display'])
    expect(runs[0]![17]).toBe(':110')
  })

  it('validates actions and maps a vanished element to its own error', async () => {
    const guest = (answer: string) => ({ ownerEnv: ['DISPLAY=:110'], run: async () => answer })
    await expect(screenAct(guest('0\n{"ok":true}'), { element: 'a b', action: 'press' })).rejects.toThrow('element must be')
    await expect(screenAct(guest('0\n{"ok":true}'), { element: '0.1', action: 'hover' })).rejects.toThrow('action must be')
    await expect(screenAct(guest('0\n{"ok":true}'), { element: '0.1', action: 'set-text' })).rejects.toThrow('set-text needs text')
    await expect(screenAct(guest('3\n{"ok":false}'), { element: '0.1', action: 'press' })).rejects.toThrow('element not found')
    expect(await screenAct(guest('0\n{"ok":true}'), { element: '400007-158-1.0.3.0.1-edc227', action: 'press' })).toEqual({ ok: true })
    await expect(screenKeys(guest('0\n'), { keys: 'ctrl+s; reboot' })).rejects.toThrow('keys must be')
    await expect(screenType(undefined, { text: 'x' })).rejects.toThrow('computer is not running')
    expect(normalizeKey('ctrl+shift+T')).toBe('ctrl+shift+t')
    expect(normalizeKey('Enter')).toBe('Return')
    expect(normalizeKey('cmd+f5')).toBe('super+F5')
  })
})
