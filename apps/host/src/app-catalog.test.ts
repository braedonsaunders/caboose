import { describe, expect, it, vi } from 'vitest'
import { AppCatalog } from './app-catalog.js'
import { loadCatalog } from './app-catalog-data.js'

const data = loadCatalog()
function setup() {
  let finish!: () => void
  const gate = new Promise<void>(resolve => { finish = resolve })
  const calls: string[] = [], events: any[] = []
  const guest = { run: vi.fn(async (_cmd: string, args: string[]) => {
    const action = args[2]!
    calls.push(action)
    if (action === 'list') return JSON.stringify({})
    await gate
    return ''
  }) }
  const release = vi.fn()
  const catalog = new AppCatalog(() => guest, event => events.push(event), () => release, data)
  return { catalog, guest, finish, calls, events, release }
}
async function settle() { for (let n = 0; n < 30; n++) await new Promise(resolve => setTimeout(resolve, 1)) }

describe('catalog operations', () => {
  it('reports pins, queues an install and holds a lease until it finishes', async () => {
    const s = setup()
    const listing = await s.catalog.list()
    expect(listing.apps.find(a => a.id === 'gridcraft')?.pinnedVersion).toBe('0.12.1')
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
    s.catalog.start('gridcraft', 'rollback')
    await settle()
    expect(s.events).toContainEqual(expect.objectContaining({ id: 'gridcraft', phase: 'failed', message: 'No previous release is available' }))
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
    const action = args[2]!
    if (action === 'list') return JSON.stringify(state)
    if (action === 'progress') return JSON.stringify((state.gridcraft as any)?.progress ?? null)
    actions.push(action)
    return execute(action, JSON.parse(args[3]!))
  }) }
  const catalog = new AppCatalog(() => guest, event => events.push(event), lease, data)
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
