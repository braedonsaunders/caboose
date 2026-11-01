import { describe, expect, it } from 'vitest'
import { AgentInputError, AgentNotFoundError, AgentOperationError, type AgentGuest } from './agents.js'
import { ComputerConflictError } from './lifecycle.js'
import { SCOPES, endRunningApp, listRunningApps, parseRunningAppId, parseRunningApps } from './running-apps.js'

const STEAM = 'app-steam-3.scope'
const process = { pid: 41, ppid: 1, name: 'steam', command: 'steam -silent', state: 'sleeping', cpuPercent: 1.5, memoryBytes: 1024 }
const app = {
  id: STEAM, kind: 'app', desktopId: 'steam.desktop', name: 'Steam', origin: 'launch', startedAt: 1_700_000_000_000,
  windows: [], cpuPercent: 12.5, memoryBytes: 1 << 30, io: { readBytesPerSecond: 0, writeBytesPerSecond: 4096 },
  gpu: null, processCount: 1, processes: [process],
}
const session = { ...app, id: 'session.scope', kind: 'session', desktopId: null, name: 'System', origin: 'session', startedAt: 0 }
const listing = (apps: unknown[]) => ({ version: 1, sampledAt: 1, intervalMs: 1000, machine: { cpus: 8, memoryBytes: 1 << 34 }, apps })

/** A guest whose caboose-scopes prints `answer` and records what was asked. */
function guest(answer: unknown): AgentGuest & { calls: string[][] } {
  const calls: string[][] = []
  return {
    calls, ownerEnv: [],
    async run(command: string, args: string[]) { calls.push([command, ...args]); return JSON.stringify(answer) },
  } as AgentGuest & { calls: string[][] }
}

describe('the running-apps listing', () => {
  it('keeps valid apps, windowless ones and the session', () => {
    const parsed = parseRunningApps(listing([app, session, { ...app, id: 'app-firefox\\x2desr-4.scope', windows: [7, 7, 9], gpu: { streams: 2, surfaces: 1, toPhoneBytesPerSecond: 10, fromPhoneBytesPerSecond: 0 } }]))
    expect(parsed.apps.map(a => a.id)).toEqual([STEAM, 'session.scope', 'app-firefox\\x2desr-4.scope'])
    expect(parsed.apps[0]!.windows).toEqual([])
    expect(parsed.apps[2]!.windows).toEqual([7, 9])
    expect(parsed.apps[2]!.gpu).toEqual({ streams: 2, surfaces: 1, toPhoneBytesPerSecond: 10, fromPhoneBytesPerSecond: 0 })
    expect(parsed.machine).toEqual({ cpus: 8, memoryBytes: 1 << 34 })
  })

  it('drops apps that fail a check and duplicates', () => {
    const bad = [
      { ...app, id: '../etc' }, { ...app, id: 'init.scope' }, { ...app, kind: 'session' }, { ...session, kind: 'app' },
      { ...app, desktopId: 'x/y.desktop' }, { ...app, name: '' }, { ...app, name: 'a\u0000b' }, { ...app, origin: 'magic' },
      { ...app, cpuPercent: -1 }, { ...app, memoryBytes: 1.5 }, { ...app, windows: ['1'] }, { ...app, io: null },
      { ...app, gpu: { streams: 1 } }, { ...app, processes: null }, 'nope',
    ]
    expect(parseRunningApps(listing([...bad, app, app])).apps).toHaveLength(1)
  })

  it('drops processes that fail a check and cleans command lines', () => {
    const parsed = parseRunningApps(listing([{ ...app, processes: [
      process, { ...process, pid: 0 }, { ...process, state: 'busy' }, { ...process, name: 'x'.repeat(65) },
      { ...process, pid: 42, command: 'a\nb\u0000c' },
    ] }]))
    expect(parsed.apps[0]!.processes.map(p => [p.pid, p.command])).toEqual([[41, 'steam -silent'], [42, 'a b c']])
    expect(parsed.apps[0]!.processCount).toBe(2)
  })

  it('refuses a listing of another version', () => {
    expect(() => parseRunningApps({ ...listing([]), version: 2 })).toThrow(AgentOperationError)
    expect(() => parseRunningApps({ ...listing([]), machine: null })).toThrow(AgentOperationError)
  })

  it('reads the listing through caboose-scopes as root', async () => {
    const computer = guest({ ok: true, result: listing([app]) })
    expect((await listRunningApps(computer)).apps[0]!.name).toBe('Steam')
    expect(computer.calls).toEqual([[SCOPES, 'list']])
  })

  it('says when the computer is not tracking apps', async () => {
    await expect(listRunningApps(guest({ ok: false, error: 'unavailable', message: 'no' }))).rejects.toThrow(ComputerConflictError)
    await expect(listRunningApps({ ownerEnv: [], run: async () => 'garbage' } as AgentGuest)).rejects.toThrow(AgentOperationError)
  })
})

describe('ending an app', () => {
  it('quits by closing its windows', async () => {
    const computer = guest({ ok: true, result: { closed: 2 } })
    expect(await endRunningApp(computer, STEAM, 'quit')).toEqual({ closed: 2 })
    expect(computer.calls).toEqual([[SCOPES, 'quit', STEAM]])
  })

  it('force quits and kills, reporting whether it ended', async () => {
    expect(await endRunningApp(guest({ ok: true, result: { ended: true, killed: false } }), STEAM, 'force-quit')).toEqual({ ended: true, killed: false })
    const computer = guest({ ok: true, result: { ended: true, killed: true } })
    expect(await endRunningApp(computer, 'app-firefox\\x2desr-4.scope', 'kill')).toEqual({ ended: true, killed: true })
    expect(computer.calls).toEqual([[SCOPES, 'kill', 'app-firefox\\x2desr-4.scope']])
  })

  it('maps the guest errors to statuses', async () => {
    await expect(endRunningApp(guest({ ok: false, error: 'unknown', message: 'x' }), STEAM, 'kill')).rejects.toThrow(AgentNotFoundError)
    await expect(endRunningApp(guest({ ok: false, error: 'no-windows', message: 'x' }), STEAM, 'quit')).rejects.toThrow(ComputerConflictError)
    await expect(endRunningApp(guest({ ok: false, error: 'invalid', message: 'bad' }), STEAM, 'quit')).rejects.toThrow(AgentInputError)
    await expect(endRunningApp(guest({ ok: false, error: 'failed', message: 'EIO' }), STEAM, 'kill')).rejects.toThrow(AgentOperationError)
    await expect(endRunningApp(guest({ ok: true, result: { closed: -1 } }), STEAM, 'quit')).rejects.toThrow(AgentOperationError)
  })

  it('never ends the session and checks ids before asking the guest', async () => {
    const computer = guest({ ok: true, result: { ended: true, killed: true } })
    await expect(endRunningApp(computer, 'session.scope', 'kill')).rejects.toThrow(ComputerConflictError)
    await expect(endRunningApp(computer, 'init.scope', 'kill')).rejects.toThrow(AgentInputError)
    expect(computer.calls).toEqual([])
    expect(() => parseRunningAppId('app-x-1.scope/../../x')).toThrow(AgentInputError)
    expect(parseRunningAppId('app-Portal\\x202-12.scope')).toBe('app-Portal\\x202-12.scope')
  })
})
