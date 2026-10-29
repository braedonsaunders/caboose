import { describe, expect, it, vi } from 'vitest'
import { AppCatalog } from './app-catalog.js'
import { loadCatalog } from './app-catalog-data.js'
import type { CraftReleases } from './releases.js'

const data = loadCatalog()
const latest = { version: '0.13.0', url: 'https://github.com/storytold/gridcraft/releases/download/v0.13.0/gridcraft-0.13.0-linux-x86_64.deb', sha256: 'a'.repeat(64), size: 1000 }
const releases = { latest: vi.fn(async () => latest), known: () => latest } as unknown as CraftReleases
function setup() {
  let finish!: () => void
  const gate = new Promise<void>(resolve => { finish = resolve })
  const calls: string[] = [], events: any[] = []
  const guest = { run: vi.fn(async (_cmd: string, args: string[]) => {
    if (args.length === 3) return '[]'
    const action = args[2]!
    calls.push(action)
    if (action === 'list') return JSON.stringify({ apps: {}, environment: {} })
    await gate
    return ''
  }) }
  const release = vi.fn()
  const catalog = new AppCatalog(() => guest, event => events.push(event), () => release, { data, releases })
  return { catalog, guest, finish, calls, events, release }
}
async function settle() { for (let n = 0; n < 30; n++) await new Promise(resolve => setTimeout(resolve, 1)) }

describe('catalog operations', () => {
  it('offers the latest release, queues an install and holds a lease until it finishes', async () => {
    const s = setup()
    const listing = await s.catalog.list()
    expect(listing.apps.find(a => a.id === 'gridcraft')).toMatchObject({ latestVersion: '0.13.0', source: { kind: 'release', size: 1000 }, curated: true, origin: 'caboose' })
    s.catalog.start('gridcraft', 'install')
    expect(s.catalog.busy).toBe(true)
    expect(() => s.catalog.start('gimp', 'install')).toThrow('in progress')
    await settle()
    expect(s.calls).toContain('install')
    expect(s.events).toContainEqual(expect.objectContaining({ type: 'catalog.progress', id: 'gridcraft', phase: 'installing' }))
    s.finish(); await settle()
    expect(s.catalog.busy).toBe(false)
    expect(s.release).toHaveBeenCalledOnce()
    expect(s.events).toContainEqual(expect.objectContaining({ type: 'catalog.progress', id: 'gridcraft', phase: 'finished' }))
    expect(s.events).toContainEqual(expect.objectContaining({ type: 'catalog.changed', id: 'gridcraft' }))
  })
  it('refuses unknown entries and surfaces failures without losing the lease', async () => {
    const s = setup()
    expect(() => s.catalog.start('missing', 'install')).toThrow('not found')
    s.catalog.start('gridcraft', 'update')
    await settle()
    expect(s.events).toContainEqual(expect.objectContaining({ id: 'gridcraft', phase: 'failed', message: 'Application is not installed' }))
    expect(s.release).toHaveBeenCalledOnce()
  })
})

describe('catalog MCP servers', () => {
  it('offers only installed apps with safe commands', async () => {
    const { craftMcpServers } = await import('./app-catalog.js')
    expect(craftMcpServers([
      { id: 'photo', installedVersion: '1', mcp: 'photocraft-cli mcp' },
      { id: 'absent', installedVersion: null, mcp: 'absent-cli mcp' },
      { id: 'no-server', installedVersion: '1' },
    ])).toEqual([{ name: 'caboose-photo', command: 'photocraft-cli', args: ['mcp'], env: [] }])
    expect(() => craftMcpServers([{ id: 'bad', installedVersion: '1', mcp: 'sh -c evil;command' }])).toThrow('Invalid MCP command')
  })
})

function controlled() {
  let state: Record<string, unknown> = {}
  const events: any[] = [], actions: string[] = []
  const release = vi.fn(), lease = vi.fn(() => release)
  let execute = async (_action: string, _app: Record<string, unknown>) => ''
  const guest = { run: vi.fn(async (_command: string, args: string[]) => {
    if (args.length === 3) return '[]'
    const action = args[2]!
    if (action === 'list') return JSON.stringify({ apps: state, environment: {} })
    if (action === 'progress') return JSON.stringify((state.gridcraft as any)?.progress ?? null)
    actions.push(action)
    return execute(action, JSON.parse(args[3]!))
  }) }
  const catalog = new AppCatalog(() => guest, event => events.push(event), lease, { data, releases })
  return { catalog, events, actions, release, lease, setState: (value: Record<string, unknown>) => { state = value }, run: (fn: typeof execute) => { execute = fn } }
}
const progress = (phase: string, stage = 'installing') => ({ operation: 'install', phase, stage, value: null })

it('reattaches to active guest work, validates progress, and holds a lease until package setup finishes', async () => {
  const s = controlled()
  s.setState({ gridcraft: { installedVersion: '0.12.1-1', active: true, interrupted: false,
    progress: { ...progress('installing', 'configuring'), id: 'spoofed', value: 0.85, downloadedBytes: 75, totalBytes: 100 } } })
  try {
    const app = (await s.catalog.list()).apps.find(app => app.id === 'gridcraft')!
    expect(app.progress).toMatchObject({ id: 'gridcraft', stage: 'configuring', value: null })
    expect(app.progress).not.toHaveProperty('downloadedBytes')
    expect(app.interrupted).toBe(false)
    expect(s.catalog.busy).toBe(true)
    expect(s.lease).toHaveBeenCalledOnce()
    expect(s.release).not.toHaveBeenCalled()
    expect(() => s.catalog.start('gridcraft', 'install')).toThrow('in progress')
    for (const stage of ['verifying', 'installing', 'configuring', 'refreshing', 'removing']) {
      s.setState({ gridcraft: { active: true, progress: { ...progress('installing', stage), value: 0.85 } } })
      expect((await s.catalog.list()).apps.find(app => app.id === 'gridcraft')?.progress?.value).toBeNull()
    }
    s.setState({ gridcraft: { active: true, progress: { ...progress('installing', 'downloading'), value: 0.75, downloadedBytes: 40, totalBytes: 100 } } })
    expect((await s.catalog.list()).apps.find(app => app.id === 'gridcraft')?.progress).toMatchObject({ value: 0.4, downloadedBytes: 40, totalBytes: 100 })
    s.setState({ gridcraft: { active: true, progress: { ...progress('installing', 'downloading'), downloadedBytes: -1, totalBytes: 0 } } })
    expect((await s.catalog.list()).apps.find(app => app.id === 'gridcraft')?.progress?.value).toBeNull()
  } finally {
    s.setState({ gridcraft: { installedVersion: '0.12.1-1', active: false, progress: progress('finished', 'finished') } })
    await expect.poll(() => s.catalog.busy, { timeout: 4000 }).toBe(false)
  }
  expect(s.actions).toEqual([])
  expect(s.release).toHaveBeenCalledOnce()
  expect(s.events).toContainEqual(expect.objectContaining({ id: 'gridcraft', phase: 'finished' }))
}, 8000)

it.each(['finished', 'failed'])('keeps the lease after a channel timeout until the guest reports %s', async outcome => {
  const s = controlled()
  let operationId: unknown
  s.run(async (_action, app) => {
    operationId = app.operationId
    s.setState({ gridcraft: { active: true, operationId, progress: progress('installing', 'configuring') } })
    throw new Error('guest command timed out')
  })
  s.catalog.start('gridcraft', 'install')
  try {
    await expect.poll(() => s.actions).toContain('install')
    await settle()
    expect(s.catalog.busy).toBe(true)
    expect(s.release).not.toHaveBeenCalled()
    expect(s.events.some(event => event.phase === 'failed')).toBe(false)
  } finally {
    s.setState({ gridcraft: { installedVersion: '0.12.1-1', operationId, active: false, interrupted: outcome === 'failed',
      progress: { ...progress(outcome, outcome === 'finished' ? 'finished' : 'configuring'), message: outcome === 'failed' ? 'Operation interrupted. Retry to complete package setup.' : undefined } } })
    await expect.poll(() => s.catalog.busy, { timeout: 4000 }).toBe(false)
  }
  expect(s.events).toContainEqual(expect.objectContaining({ id: 'gridcraft', phase: outcome }))
  expect(s.release).toHaveBeenCalledOnce()
}, 8000)

it.each(['interrupted', 'lastError'])('retries package setup for an installed app with %s', async field => {
  const s = controlled()
  s.setState({ gridcraft: { installedVersion: '0.12.1-1', [field]: field === 'interrupted' ? true : 'trigger failed', progress: progress('failed') } })
  s.run(async () => {
    s.setState({ gridcraft: { installedVersion: '0.12.1-1', progress: progress('finished', 'finished') } })
    return ''
  })
  s.catalog.start('gridcraft', 'install')
  await expect.poll(() => s.catalog.busy).toBe(false)
  expect(s.actions).toEqual(['install'])
  expect(s.events).toContainEqual(expect.objectContaining({ phase: 'finished' }))
})

it('does not mistake a previous successful attempt for a new command failure', async () => {
  const s = controlled()
  s.setState({ gridcraft: { operationId: 'old-attempt', active: false, progress: progress('finished', 'finished') } })
  s.run(async () => { throw new Error('guest channel unavailable') })
  s.catalog.start('gridcraft', 'install')
  await expect.poll(() => s.catalog.busy).toBe(false)
  expect(s.events).toContainEqual(expect.objectContaining({ phase: 'failed', message: 'guest channel unavailable' }))
  expect(s.events.some(event => event.phase === 'finished')).toBe(false)
})

it('rehydrates stored applications before listing and accepting operations after a host restart', async () => {
  const app = { id: 'debian-mousepad', package: 'mousepad', componentId: 'org.xfce.mousepad', desktopId: 'org.xfce.mousepad.desktop', name: 'Mousepad', summary: 'Text editor', categories: ['Utility'], curated: false, license: 'GPL-2.0+' }
  let restores = 0
  const guest = { run: vi.fn(async (_command: string, args: string[]) => {
    if (args.length === 3) { expect(JSON.parse(args[2]!)).toEqual({ restore: true }); restores++; return JSON.stringify([app]) }
    if (args[2] === 'list') return JSON.stringify({ apps: { 'debian-mousepad': { installedVersion: '1.0', active: false } }, environment: {} })
    return ''
  }) }
  const catalog = new AppCatalog(() => guest, () => {}, () => () => {}, data)
  expect((await catalog.list()).apps.find(item => item.id === app.id)?.installedVersion).toBe('1.0')
  expect(restores).toBe(1)
  expect(() => catalog.start(app.id, 'remove')).not.toThrow()
  await settle()
  expect(restores).toBe(1)
})

describe('Flathub in the Library', () => {
  async function library(options: { depot?: boolean; environment?: Record<string, unknown> } = {}) {
    const { mkdtempSync } = await import('node:fs'), { tmpdir } = await import('node:os'), { join } = await import('node:path')
    const { FlathubIndex } = await import('./flathub.js'), { hit } = await import('./flathub.test.js')
    const hits = [hit('org.gimp.GIMP', { name: 'GIMP', installs_last_month: 900 }), hit('org.mozilla.firefox', { name: 'Firefox', main_categories: 'network', installs_last_month: 800 }),
      ...Array.from({ length: 120 }, (_, i) => hit(`org.example.Paint${i}`, { name: `Paint ${i}`, installs_last_month: i }))]
    const fetcher = vi.fn(async (url: string) => url.endsWith('.png') ? { ok: false, status: 404, json: async () => ({}), arrayBuffer: async () => new ArrayBuffer(0) }
      : { ok: true, status: 200, json: async () => ({ hits, totalPages: 1 }), arrayBuffer: async () => new ArrayBuffer(0) })
    const flathub = new FlathubIndex(mkdtempSync(join(tmpdir(), 'caboose-library-')), 'x86_64', fetcher)
    const calls: Array<{ action: string; argument: any }> = []
    let apps: Record<string, unknown> = {}
    const guest = { run: vi.fn(async (_command: string, args: string[]) => {
      if (args.length === 3) return '[]'
      const action = args[2]!, argument = JSON.parse(args[3]!)
      if (action === 'list') return JSON.stringify({ apps, environment: options.environment ?? { flatpak: true, depot: !!options.depot } })
      if (action === 'progress') return 'null'
      calls.push({ action, argument })
      if (action === 'updates') return JSON.stringify({ flatpak: ['org.mozilla.firefox'], apt: [] })
      if (action === 'install') apps = { ...apps, [argument.id]: { installedVersion: '1.0', flatpak: { version: '1.0', name: 'Firefox', summary: 'Browser', runtime: 'org.freedesktop.Platform/x86_64/25.08' }, progress: { operation: 'install', phase: 'finished', stage: 'finished' } } }
      return ''
    }) }
    const ensure = vi.fn(async (_runtime: string, onProgress: (p: { message: string }) => void) => { onProgress({ message: 'Adding Freedesktop 25.08' }) })
    const depot = options.depot ? { enabled: true, ensure, has: () => true, note: vi.fn(async () => {}), maintain: vi.fn(async () => {}) } : undefined
    const events: any[] = []
    let now = 0
    const catalog = new AppCatalog(() => guest, event => events.push(event), () => () => {}, { data, releases, flathub, ...(depot ? { depot: depot as never } : {}), now: () => now })
    return { catalog, calls, events, ensure, depot, setApps: (value: Record<string, unknown>) => { apps = value }, advance: (ms: number) => { now += ms } }
  }

  it('ranks curated apps first, hides Flathub copies of them, and pages the rest by popularity', async () => {
    const { catalog } = await library()
    const first = await catalog.discover('')
    expect(first.total).toBe(data.apps.length + 121)
    expect(first.apps.slice(0, data.apps.length > 40 ? 40 : data.apps.length).every(app => app.curated)).toBe(true)
    const all = [...first.apps]
    for (let offset = 40; offset < first.total; offset += 40) all.push(...(await catalog.discover('', '', offset)).apps)
    expect(all.map(app => app.id)).not.toContain('flathub-org.gimp.GIMP')
    const flathub = all.filter(app => app.origin === 'flathub')
    expect(flathub[0]).toMatchObject({ id: 'flathub-org.mozilla.firefox', desktopId: 'org.mozilla.firefox.desktop', source: { kind: 'flatpak' }, curated: false, verified: true, installs: 800 })
    expect((await catalog.discover('paint 7')).apps[0]?.name).toBe('Paint 7')
    expect((await catalog.discover('', 'Internet')).apps.map(app => app.id)).toEqual(['flathub-org.mozilla.firefox'])
    await expect(catalog.discover('', 'Nonsense')).rejects.toThrow('Unknown category')
  })
  it('adds the runtime to the shared depot before the guest installs the app on it', async () => {
    const s = await library({ depot: true })
    await s.catalog.ready(); await s.catalog.list()
    s.catalog.start('flathub-org.mozilla.firefox', 'install')
    await expect.poll(() => s.calls.some(call => call.action === 'install')).toBe(true)
    expect(s.ensure).toHaveBeenCalledWith('org.gnome.Platform/x86_64/49', expect.any(Function))
    expect(s.calls.find(call => call.action === 'install')!.argument.source).toEqual({ kind: 'flatpak', appId: 'org.mozilla.firefox', runtime: 'org.gnome.Platform/x86_64/49' })
    expect(s.events).toContainEqual(expect.objectContaining({ id: 'flathub-org.mozilla.firefox', stage: 'preparing', message: 'Adding Freedesktop 25.08' }))
    await expect.poll(() => s.catalog.busy).toBe(false)
    const listed = (await s.catalog.list()).apps.find(app => app.id === 'flathub-org.mozilla.firefox')
    expect(listed).toMatchObject({ installedVersion: '1.0', name: 'Firefox', origin: 'flathub' })
    expect(s.depot!.note).toHaveBeenCalledWith('owner', ['org.freedesktop.Platform/x86_64/25.08'])
  })
  it('installs without the depot on a computer that does not mount it, and refuses before Flatpak exists', async () => {
    const s = await library({ depot: true, environment: { flatpak: true, depot: false } })
    await s.catalog.ready(); await s.catalog.list()
    s.catalog.start('flathub-org.mozilla.firefox', 'install')
    await expect.poll(() => s.calls.some(call => call.action === 'install')).toBe(true)
    expect(s.ensure).not.toHaveBeenCalled()
    const old = await library({ environment: { flatpak: false } })
    await old.catalog.ready(); await old.catalog.list()
    old.catalog.start('flathub-org.mozilla.firefox', 'install')
    await expect.poll(() => old.events.some(event => event.phase === 'failed')).toBe(true)
    expect(old.events).toContainEqual(expect.objectContaining({ phase: 'failed', message: expect.stringContaining('Flatpak is not installed') }))
  })
  it('updates installed apps once a day, runtimes first', async () => {
    const s = await library({ depot: true })
    s.setApps({ 'flathub-org.mozilla.firefox': { installedVersion: '1.0', flatpak: { version: '1.0', name: 'Firefox', summary: 'Browser', runtime: null } } })
    await s.catalog.ready()
    await s.catalog.autoUpdate()
    expect(s.depot!.maintain).toHaveBeenCalledOnce()
    await expect.poll(() => s.calls.filter(call => call.action === 'update').map(call => call.argument.id)).toEqual(['flathub-org.mozilla.firefox'])
    await expect.poll(() => s.catalog.busy).toBe(false)
    await s.catalog.autoUpdate()
    expect(s.calls.filter(call => call.action === 'updates')).toHaveLength(1)
    s.advance(25 * 3600_000)
    await s.catalog.autoUpdate()
    expect(s.calls.filter(call => call.action === 'updates')).toHaveLength(2)
  })
})

it('browses a collection as its apps, then popular apps in its category, and never installs it whole', async () => {
  const { mkdtempSync } = await import('node:fs'), { tmpdir } = await import('node:os'), { join } = await import('node:path')
  const { FlathubIndex } = await import('./flathub.js'), { hit } = await import('./flathub.test.js')
  const hits = Array.from({ length: 120 }, (_, i) => hit(`org.example.Video${i}`, { name: `Video ${i}`, main_categories: 'audiovideo', installs_last_month: i }))
  const fetcher = vi.fn(async (url: string) => url.endsWith('.png') ? { ok: false, status: 404, json: async () => ({}), arrayBuffer: async () => new ArrayBuffer(0) }
    : { ok: true, status: 200, json: async () => ({ hits, totalPages: 1 }), arrayBuffer: async () => new ArrayBuffer(0) })
  const flathub = new FlathubIndex(mkdtempSync(join(tmpdir(), 'caboose-collection-')), 'x86_64', fetcher)
  const catalog = new AppCatalog(() => undefined, () => {}, () => () => {}, { data, releases, flathub })
  const pack = data.packs.find(item => item.id === 'video-audio')!
  const members = data.apps.filter(app => app.packs.includes(pack.id)).map(app => app.id)
  const page = await catalog.discover('', '', 0, 'video-audio')
  expect(page.apps.slice(0, members.length).map(app => app.id)).toEqual(members)
  expect(page.apps[members.length]).toMatchObject({ id: 'flathub-org.example.Video119', origin: 'flathub' })
  expect((await catalog.discover('', '', 0, 'creative-studio')).apps.every(app => app.curated)).toBe(true)
  await expect(catalog.discover('', 'Games', 0, 'video-audio')).rejects.toThrow('not both')
  await expect(catalog.discover('', '', 0, 'missing')).rejects.toThrow('Collection not found')
  expect('startPack' in catalog).toBe(false)
})
