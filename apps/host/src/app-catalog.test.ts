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
