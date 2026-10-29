import { describe, expect, it } from 'vitest'
import {
  actionLabel, appActions, appendPage, catalogBusy, displayVersion, isPending, nextOffset, packApps, packMissing, progressSummary,
  withLiveState, type CatalogApp, type CatalogResponse,
} from './catalog.js'

function app(id: string, overrides: Partial<CatalogApp> = {}): CatalogApp {
  return {
    id, name: id[0]!.toUpperCase() + id.slice(1), summary: `${id} summary`, category: 'Create', categories: ['Create'], packs: ['studio'],
    desktopId: `${id}.desktop`, fileTypes: { extensions: [], utTypes: [] }, iconData: null, source: { kind: 'apt' }, curated: true,
    origin: 'caboose', developer: null, verified: false, license: null, installs: null, installedVersion: null, latestVersion: null,
    updateAvailable: false, lastError: null, interrupted: false, active: false, progress: null, ...overrides,
  }
}

function flathub(appId: string, overrides: Partial<CatalogApp> = {}): CatalogApp {
  return app(`flathub-${appId}`, {
    desktopId: `${appId}.desktop`, packs: [], source: { kind: 'flatpak', size: 1000 }, curated: false, origin: 'flathub', ...overrides,
  })
}

describe('catalog', () => {
  it('offers install for a missing app and update now and remove for an installed one', () => {
    expect(appActions(app('a'))).toEqual(['install'])
    expect(appActions(app('a', { installedVersion: '1.0.0' }))).toEqual(['remove'])
    expect(appActions(app('a', { installedVersion: '1.0.0', updateAvailable: true }))).toEqual(['update', 'remove'])
    expect(actionLabel(app('a'), 'install')).toBe('Install')
    expect(actionLabel(app('a', { lastError: 'x' }), 'install')).toBe('Retry')
    expect(actionLabel(app('a', { interrupted: true }), 'install')).toBe('Retry')
    expect(actionLabel(app('a'), 'update')).toBe('Update now')
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
    expect(progressSummary({ id: 'a', operation: 'update', phase: 'failed', message: 'x' })).toEqual({ label: 'Updating failed' })
    expect(progressSummary({ id: 'a', operation: 'remove', phase: 'finished' })).toEqual({ label: 'Removed' })
  })

  it('groups packs and counts what is missing', () => {
    const catalog: CatalogResponse = {
      packs: [{ id: 'studio', name: 'Studio' }, { id: 'office', name: 'Office' }],
      apps: [app('a', { installedVersion: '1' }), app('b'), app('c', { packs: ['office'] })],
    }
    expect(packApps(catalog, 'studio').map(entry => entry.id)).toEqual(['a', 'b'])
    expect(packMissing(catalog, 'studio')).toBe(1)
    expect(packMissing(catalog, 'office')).toBe(1)
  })

  it('trims Debian revisions from Debian versions only', () => {
    expect(displayVersion('7.6.1-1+b2')).toBe('7.6.1')
    expect(displayVersion('7.6.1-1+b2', { kind: 'apt' })).toBe('7.6.1')
    expect(displayVersion('0.16.0')).toBe('0.16.0')
    expect(displayVersion('2.0.0-beta2', { kind: 'flatpak' })).toBe('2.0.0-beta2')
  })
})

describe('library', () => {
  it('shows each row with the catalog state, and clears what an app left out no longer has', () => {
    const page = [
      app('gimp'),
      flathub('org.mozilla.firefox'),
      flathub('org.kde.krita', { installedVersion: '5.2', progress: { id: 'flathub-org.kde.krita', operation: 'remove', phase: 'queued' } }),
    ]
    const catalog: CatalogResponse = {
      packs: [],
      apps: [
        app('gimp', { installedVersion: '3.0' }),
        flathub('org.mozilla.firefox', { active: true, progress: { id: 'flathub-org.mozilla.firefox', operation: 'install', phase: 'installing' } }),
      ],
    }
    const shown = withLiveState(page, catalog)
    expect(shown[0]!.installedVersion).toBe('3.0')
    expect(shown[1]!.progress?.phase).toBe('installing')
    expect(shown[2]).toMatchObject({ installedVersion: null, progress: null, active: false, lastError: null })
    expect(withLiveState(page, null)).toBe(page)
  })

  it('keeps a curated row the catalog does not list as it came', () => {
    const curated = app('photocraft', { installedVersion: '1.0' })
    expect(withLiveState([curated], { packs: [], apps: [] })[0]).toBe(curated)
  })

  it('appends pages without repeating an app and stops at the total or an empty page', () => {
    const first = [app('gimp'), flathub('org.mozilla.firefox')]
    const next = [flathub('org.mozilla.firefox'), flathub('org.kde.krita'), flathub('org.kde.krita')]
    expect(appendPage(first, next).map(entry => entry.id)).toEqual(['gimp', 'flathub-org.mozilla.firefox', 'flathub-org.kde.krita'])
    expect(nextOffset({ apps: first, offset: 0, total: 3300 })).toBe(2)
    expect(nextOffset({ apps: first, offset: 3298, total: 3300 })).toBeNull()
    expect(nextOffset({ apps: [], offset: 40, total: 3300 })).toBeNull()
  })
})
