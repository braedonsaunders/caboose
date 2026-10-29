import { mkdtempSync, readFileSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { afterEach, describe, expect, it, vi } from 'vitest'
import { lines, RuntimeDepot, runtimeLabel, type DepotRunner } from './depot.js'

const roots: string[] = []
afterEach(() => { for (const root of roots.splice(0)) rmSync(root, { recursive: true, force: true }) })
const file = () => { const dir = mkdtempSync(join(tmpdir(), 'caboose-depot-')); roots.push(dir); return join(dir, 'depot.json') }
const GNOME = 'org.gnome.Platform/x86_64/49', KDE = 'org.kde.Platform/x86_64/6.9'

function runner() {
  const runs: string[][] = []
  let installed: string[] = []
  const gates: Array<() => void> = []
  const run: DepotRunner = async (args, onEvent) => {
    runs.push(args)
    if (args[0] === 'ensure') {
      onEvent({ type: 'ready', size: 100 })
      await new Promise<void>(resolve => gates.push(resolve))
      onEvent({ type: 'progress', downloaded: 50, size: 100 })
      installed = [...new Set([...installed, JSON.parse(args[1]!) as string])]
    }
    if (args[0] === 'collect') installed = installed.filter(ref => (JSON.parse(args[1]!) as string[]).includes(ref))
    onEvent({ type: 'state', runtimes: installed, bytes: installed.length * 1000 })
  }
  return { run, runs, open: () => gates.shift()?.() }
}
async function settle() { for (let n = 0; n < 20; n++) await new Promise(resolve => setTimeout(resolve, 1)) }

describe('runtime depot', () => {
  it('builds each runtime once, one builder at a time, and reports its download', async () => {
    const r = runner(), depot = new RuntimeDepot(r.run, file())
    const progress: unknown[] = []
    const first = depot.ensure(GNOME, p => progress.push(p)), again = depot.ensure(GNOME), other = depot.ensure(KDE)
    await settle()
    expect(r.runs).toEqual([['ensure', JSON.stringify(GNOME)]])
    r.open(); await first; await again
    await settle()
    expect(r.runs).toHaveLength(2)
    r.open(); await other
    expect(progress).toEqual([{ message: "Adding GNOME 49 to this host's shared runtimes" }, { message: 'Downloading GNOME 49 for every computer on this host', downloadedBytes: 50, totalBytes: 100 }])
    expect(depot.has(GNOME) && depot.has(KDE)).toBe(true)
    expect(await depot.status()).toEqual({ enabled: true, runtimes: [GNOME, KDE], bytes: 2000 })
    await expect(depot.ensure('../../etc')).rejects.toThrow('Invalid runtime')
  })
  it('keeps the runtimes any computer used within 30 days and forgets deleted computers', async () => {
    let now = 1_000_000_000_000
    const r = runner(), path = file(), depot = new RuntimeDepot(r.run, path, () => now)
    const both = Promise.all([depot.ensure(GNOME), depot.ensure(KDE)])
    await settle(); r.open(); await settle(); r.open(); await both
    await depot.note('owner', [GNOME])
    await depot.note('alex', [KDE])
    now += 31 * 86400_000
    await depot.note('owner', [GNOME])
    await depot.maintain()
    expect(r.runs.slice(-2)).toEqual([['update'], ['collect', JSON.stringify([GNOME])]])
    expect(depot.has(KDE)).toBe(false)
    await depot.forget('owner')
    expect(JSON.parse(readFileSync(path, 'utf8')).usage).toEqual({ alex: { [KDE]: now - 31 * 86400_000 } })
    await depot.maintain()
    expect(r.runs.filter(run => run[0] === 'update')).toHaveLength(1)
  })
  it('refuses work without a builder', async () => {
    const depot = new RuntimeDepot(null, file())
    expect(depot.enabled).toBe(false)
    await expect(depot.ensure(GNOME)).rejects.toThrow('does not share runtimes')
    await depot.maintain()
  })
  it('names runtimes for people and parses builder output across chunks', () => {
    expect(runtimeLabel(GNOME)).toBe('GNOME 49')
    expect(runtimeLabel('org.freedesktop.Platform/x86_64/25.08')).toBe('Freedesktop 25.08')
    const events: unknown[] = [], feed = lines(event => events.push(event))
    feed(Buffer.from('{"type":"rea')); feed(Buffer.from('dy"}\nnot json\n[1]\n{"type":"done"}\n'))
    expect(events).toEqual([{ type: 'ready' }, { type: 'done' }])
  })
})

vi.setConfig({ testTimeout: 10_000 })
