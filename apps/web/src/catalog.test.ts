import { describe, expect, it } from 'vitest'
import {
  appActions, catalogBusy, displayVersion, isPending, launchableFor, matchesQuery, packApps, packMissing, progressSummary,
  type CatalogApp, type CatalogResponse,
} from './catalog.js'

function app(id: string, overrides: Partial<CatalogApp> = {}): CatalogApp {
  return {
    id, name: id[0]!.toUpperCase() + id.slice(1), summary: `${id} summary`, category: 'Create', packs: ['studio'], icon: id,
    desktopId: `${id}.desktop`, source: { kind: 'apt', packages: [id] }, installedVersion: null, canRollback: false, lastError: null,
    interrupted: false, iconData: null, pinnedVersion: null, updateAvailable: false, progress: null, ...overrides,
  }
}

describe('catalog', () => {
  it('offers install for a missing app and update, rollback and remove for an installed one', () => {
    expect(appActions(app('a'))).toEqual(['install'])
    expect(appActions(app('a', { installedVersion: '1.0.0' }))).toEqual(['remove'])
    expect(appActions(app('a', { installedVersion: '1.0.0', updateAvailable: true, canRollback: true }))).toEqual(['update', 'rollback', 'remove'])
  })

  it('is busy while an operation is queued or installing, not after it finishes or fails', () => {
    const catalog = (phase: 'queued' | 'installing' | 'finished' | 'failed'): CatalogResponse => ({
      packs: [], apps: [app('a', { progress: { id: 'a', operation: 'install', phase } })],
    })
    expect(catalogBusy(catalog('queued'))).toBe(true)
    expect(catalogBusy(catalog('installing'))).toBe(true)
    expect(catalogBusy(catalog('finished'))).toBe(false)
    expect(catalogBusy(catalog('failed'))).toBe(false)
    expect(catalogBusy(null)).toBe(false)
    expect(isPending(null)).toBe(false)
  })

  it('describes progress with a clamped percentage only when the installer estimates one', () => {
    expect(progressSummary({ id: 'a', operation: 'install', phase: 'queued' })).toEqual({ label: 'Queued' })
    expect(progressSummary({ id: 'a', operation: 'install', phase: 'installing', stage: 'downloading', value: 0.375 }))
      .toEqual({ label: 'Installing · downloading', percent: 38 })
    expect(progressSummary({ id: 'a', operation: 'update', phase: 'installing', stage: 'installing', value: null })).toEqual({ label: 'Updating' })
    expect(progressSummary({ id: 'a', operation: 'update', phase: 'installing', value: 7 })).toEqual({ label: 'Updating', percent: 100 })
    expect(progressSummary({ id: 'a', operation: 'rollback', phase: 'failed', message: 'x' })).toEqual({ label: 'Rolling back failed' })
    expect(progressSummary({ id: 'a', operation: 'remove', phase: 'finished' })).toEqual({ label: 'Removed' })
  })

  it('groups packs, counts what is missing, and finds the launchable entry by desktop id', () => {
    const catalog: CatalogResponse = {
      packs: [{ id: 'studio', name: 'Studio' }, { id: 'office', name: 'Office' }],
      apps: [app('a', { installedVersion: '1' }), app('b'), app('c', { packs: ['office'] })],
    }
    expect(packApps(catalog, 'studio').map(entry => entry.id)).toEqual(['a', 'b'])
    expect(packMissing(catalog, 'studio')).toBe(1)
    expect(packMissing(catalog, 'office')).toBe(1)
    const launchable = [{ id: 'b.desktop', name: 'B', icon: '', categories: [], exec: 'b' }]
    expect(launchableFor(catalog.apps[1]!, launchable)?.id).toBe('b.desktop')
    expect(launchableFor(catalog.apps[0]!, launchable)).toBeUndefined()
    expect(launchableFor(catalog.apps[0]!, null)).toBeUndefined()
  })

  it('searches names, summaries and categories, and trims Debian revisions from versions', () => {
    expect(matchesQuery(app('photocraft'), 'PHOTO')).toBe(true)
    expect(matchesQuery(app('photocraft'), 'create')).toBe(true)
    expect(matchesQuery({ name: 'Terminal', categories: ['System'] }, 'system')).toBe(true)
    expect(matchesQuery(app('photocraft'), 'video')).toBe(false)
    expect(matchesQuery(app('photocraft'), '  ')).toBe(true)
    expect(displayVersion('7.6.1-1+b2')).toBe('7.6.1')
    expect(displayVersion('0.16.0')).toBe('0.16.0')
  })
})
