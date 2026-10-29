import { describe, expect, it } from 'vitest'
import {
  CabooseApiError, CabooseClient, DEFAULT_LIMITS, buildInviteLink, buildPairingLink, computeSettingsPatch, settingsSavePatch, formatPairingCode, readSessionToken,
  validateSettingsInput, willRequireColdRestart, writeSessionToken, type ComputerSettings,
} from './api.js'
import { navigationGroups, parseRoute, routeHref, sidebarPath } from './navigation.js'
import { quotaDraft, quotasFromDraft } from './tenants.js'
import { availableActions, idleChoices, memoryChoices, stateLabel } from './state.js'

const settings: ComputerSettings = { name: 'Studio', memoryMb: 4096, vcpus: 2, idleMs: 600_000 }

describe('settings', () => {
  it('accepts the host bounds and trims the name', () => {
    const result = validateSettingsInput({ ...settings, name: '  Studio  ' })
    expect(result).toEqual({ ok: true, value: settings })
  })

  it('rejects what the host would reject, field by field', () => {
    const result = validateSettingsInput({ name: 'bad\u0007', memoryMb: 100, vcpus: 1.5, idleMs: 1_000 }, DEFAULT_LIMITS)
    expect(result.ok).toBe(false)
    if (result.ok) return
    expect(Object.keys(result.errors).sort()).toEqual(['idleMs', 'memoryMb', 'name', 'vcpus'])
  })

  it('sends only what changed', () => {
    expect(computeSettingsPatch(settings, { ...settings, name: ' Studio ', vcpus: 4 })).toEqual({ vcpus: 4 })
    expect(computeSettingsPatch(settings, settings)).toEqual({})
  })

  it('does not send a stale preset with an unrelated edit', () => {
    const external = { ...settings, memoryMb: 8192, vcpus: 8 }
    const nameOnly = computeSettingsPatch(external, { ...external, name: 'New name' })
    expect(settingsSavePatch(nameOnly, 'standard')).toEqual({ name: 'New name' })
    expect(settingsSavePatch({ name: 'New name', memoryMb: 4096, vcpus: 4 }, 'standard')).toEqual({ name: 'New name', size: 'standard' })
    expect(settingsSavePatch({ vcpus: 3 }, 'custom')).toEqual({ vcpus: 3 })
  })

  it('knows when new resources need a cold restart', () => {
    const running = { activeResources: { memoryMb: 4096, vcpus: 2 }, restartRequired: false }
    expect(willRequireColdRestart(running, { memoryMb: 4096, vcpus: 2 })).toBe(false)
    expect(willRequireColdRestart(running, { memoryMb: 8192, vcpus: 2 })).toBe(true)
    // Unknown resources (a legacy snapshot) defer to the host's own verdict.
    expect(willRequireColdRestart({ activeResources: null, restartRequired: true }, settings)).toBe(true)
  })

  it('offers whole-gigabyte memory steps inside the limits, keeping an odd current value', () => {
    expect(memoryChoices(1024, 4096)).toEqual([1024, 2048, 3072, 4096])
    expect(memoryChoices(1024, 4096, 1536)).toEqual([1024, 1536, 2048, 3072, 4096])
    expect(idleChoices(60_000, 600_000)).toEqual([60_000, 300_000, 600_000])
  })
})

describe('session token', () => {
  it('survives a browser that refuses storage', () => {
    const hostile = {
      getItem: () => { throw new DOMException('denied', 'SecurityError') },
      setItem: () => { throw new DOMException('denied', 'SecurityError') },
      removeItem: () => { throw new DOMException('denied', 'SecurityError') },
    }
    expect(readSessionToken(hostile)).toBe('')
    expect(() => writeSessionToken('secret', hostile)).not.toThrow()
  })

  it('stores trimmed and clears on empty', () => {
    const values = new Map<string, string>()
    const storage = {
      getItem: (key: string) => values.get(key) ?? null,
      setItem: (key: string, value: string) => { values.set(key, value) },
      removeItem: (key: string) => { values.delete(key) },
    }
    writeSessionToken('  secret ', storage)
    expect(readSessionToken(storage)).toBe('secret')
    writeSessionToken('', storage)
    expect(readSessionToken(storage)).toBe('')
  })

  it('builds the caboose:// pairing link the iOS app parses, with a code and never a token', () => {
    expect(buildPairingLink('https://computer.example.com/', 'ABCD2345')).toBe(
      'caboose://connect?host=https%3A%2F%2Fcomputer.example.com&code=ABCD2345')
    expect(formatPairingCode('ABCD2345')).toBe('ABCD-2345')
  })
})

describe('client', () => {
  it('sends the token only as a bearer header, and reports the host error', async () => {
    const seen: Array<{ url: string; init: RequestInit | undefined }> = []
    const fetchImpl: typeof fetch = async (url, init) => {
      seen.push({ url: String(url), init })
      return new Response(JSON.stringify({ error: 'name must be 1–80 characters' }), { status: 400 })
    }
    const client = new CabooseClient(() => 'owner-token', '', fetchImpl)
    const failure = await client.updateSettings({ name: '' }).catch(error => error)
    expect(failure).toBeInstanceOf(CabooseApiError)
    expect(failure.status).toBe(400)
    expect(failure.message).toBe('name must be 1–80 characters')
    expect(seen[0]?.url).toBe('/v1/computer/settings')
    expect(seen[0]?.url).not.toContain('owner-token')
    expect((seen[0]?.init?.headers as Record<string, string>).Authorization).toBe('Bearer owner-token')
    expect(seen[0]?.init?.method).toBe('PATCH')
  })

  it('calls fetch without a receiver, as browsers require of the native one', async () => {
    const native = globalThis.fetch
    let receiver: unknown = 'unset'
    globalThis.fetch = function (this: unknown) {
      receiver = this
      if (this !== undefined && this !== globalThis) throw new TypeError("Failed to execute 'fetch' on 'Window': Illegal invocation")
      return Promise.resolve(new Response('{"state":"parked"}', { status: 200 }))
    } as typeof fetch
    try {
      await new CabooseClient(() => 't').computer()
      expect(receiver === undefined || receiver === globalThis).toBe(true)
      let injected: unknown = 'unset'
      await new CabooseClient(() => 't', '', function (this: unknown) {
        injected = this
        return Promise.resolve(new Response('{}', { status: 200 }))
      } as typeof fetch).computer()
      expect(injected).toBeUndefined()
    } finally {
      globalThis.fetch = native
    }
  })

  it('confirms restarts in the request body', async () => {
    let body: unknown
    const client = new CabooseClient(() => 't', '', async (_url, init) => {
      body = JSON.parse(String(init?.body))
      return new Response('{}', { status: 200 })
    })
    await client.restart()
    expect(body).toEqual({ confirm: true })
  })

  it('marks unauthorized responses so the console can sign out', async () => {
    const client = new CabooseClient(() => 'stale', '', async () => new Response('{"error":"unauthorized"}', { status: 401 }))
    const failure = await client.computer().catch(error => error)
    expect(failure.isUnauthorized).toBe(true)
  })
})

describe('navigation and actions', () => {
  it('maps any path onto a page, so SPA fallbacks land somewhere real', () => {
    expect(parseRoute('/')).toEqual({ page: 'overview' })
    expect(parseRoute('/host/')).toEqual({ page: 'host' })
    expect(parseRoute('/computers')).toEqual({ page: 'computers' })
    expect(parseRoute('/computers/c-0123456789')).toEqual({ page: 'computer', id: 'c-0123456789', tab: 'overview' })
    expect(parseRoute('/computers/owner/files?path=Documents')).toEqual({ page: 'computer', id: 'owner', tab: 'files' })
    expect(parseRoute('/computers/owner/nope')).toEqual({ page: 'computer', id: 'owner', tab: 'overview' })
    expect(parseRoute('/computers/Not%20An%20Id')).toEqual({ page: 'computers' })
    expect(parseRoute('/computerish')).toEqual({ page: 'overview' })
    expect(parseRoute('/nope')).toEqual({ page: 'overview' })
  })

  it("sends addresses from earlier consoles to the owner's computer, or the page that took them over", () => {
    expect(parseRoute('/computer')).toEqual({ page: 'computer', id: 'owner', tab: 'overview' })
    expect(parseRoute('/computer/phones')).toEqual({ page: 'computer', id: 'owner', tab: 'phones' })
    expect(parseRoute('/files')).toEqual({ page: 'computer', id: 'owner', tab: 'files' })
    expect(parseRoute('/apps/')).toEqual({ page: 'computer', id: 'owner', tab: 'apps' })
    expect(parseRoute('/devices')).toEqual({ page: 'computer', id: 'owner', tab: 'phones' })
    expect(parseRoute('/settings')).toEqual({ page: 'computer', id: 'owner', tab: 'settings' })
    expect(parseRoute('/system/x')).toEqual({ page: 'host' })
    expect(parseRoute('/agents')).toEqual({ page: 'overview' })
  })

  it('writes one canonical address per page and files every computer under Computers', () => {
    expect(routeHref({ page: 'computer', id: 'owner', tab: 'overview' })).toBe('/computers/owner')
    expect(routeHref({ page: 'computer', id: 'c-0123456789', tab: 'phones' })).toBe('/computers/c-0123456789/phones')
    expect(sidebarPath({ page: 'computer', id: 'owner', tab: 'settings' })).toBe('/computers')
    expect(sidebarPath({ page: 'host' })).toBe('/host')
  })

  it('knows the pages for people, tenants, setting up and invitations', () => {
    expect(parseRoute('/people')).toEqual({ page: 'people' })
    expect(parseRoute('/tenants/')).toEqual({ page: 'tenants' })
    expect(parseRoute('/setup?code=abc')).toEqual({ page: 'setup' })
    expect(parseRoute('/invite?token=abc')).toEqual({ page: 'invite' })
    expect(routeHref({ page: 'tenants' })).toBe('/tenants')
  })

  it('shows tenants and the host only to the operator', () => {
    expect(navigationGroups(true).map(group => group.label)).toEqual(['Overview', 'Computers', 'People', 'Tenants', 'Host'])
    expect(navigationGroups(false).map(group => group.label)).toEqual(['Overview', 'Computers', 'People'])
  })

  it('never sends account, tenant or invitation routes under a computer', async () => {
    const seen: string[] = []
    const client = new CabooseClient(() => '', '', async url => { seen.push(String(url)); return new Response('{}', { status: 200 }) }).forComputer('c-0123456789')
    await client.me()
    await client.tenants()
    await client.invite('11111111-1111-4111-8111-111111111111', 'a@example.com')
    await client.invitation('tok')
    await client.signIn('a@example.com', 'pw')
    await client.updateComputer('c-0123456789', { tenantId: 'tenant', personId: 'person' })
    expect(seen).toEqual([
      '/v1/me', '/v1/tenants', '/v1/tenants/11111111-1111-4111-8111-111111111111/invites', '/v1/invites/tok', '/v1/auth/sign-in/email', '/v1/computers/c-0123456789',
    ])
    expect(buildInviteLink('https://caboose.example.com/', 'a-b_c')).toBe('https://caboose.example.com/invite?token=a-b_c')
  })

  it('reads quotas as typed, in GiB, with empty for no limit', () => {
    expect(quotasFromDraft({ memoryGb: '16', vcpus: '', diskGb: ' 200 ' })).toEqual({ ok: true, quotas: { memoryMb: 16384, vcpus: null, diskGb: 200 } })
    expect(quotasFromDraft({ memoryGb: '1.5', vcpus: '', diskGb: '' })).toMatchObject({ ok: false, error: expect.stringMatching(/whole number/) })
    expect(quotasFromDraft({ memoryGb: '', vcpus: '0', diskGb: '' })).toMatchObject({ ok: false })
    expect(quotaDraft({ memoryMb: 8192, vcpus: 4, diskGb: null })).toEqual({ memoryGb: '8', vcpus: '4', diskGb: '' })
  })

  it("sends a computer's routes under its id, and host routes as they are", async () => {
    const seen: string[] = []
    const client = new CabooseClient(() => 't', '', async url => { seen.push(String(url)); return new Response('{"computers":[],"items":[]}', { status: 200 }) })
    const kids = client.forComputer('c-0123456789')
    await kids.computer()
    await kids.listFiles('Documents')
    await kids.startCatalogOperation('photocraft', 'install')
    await kids.health()
    await kids.computers()
    await kids.phones('c-0123456789')
    await client.computer()
    expect(seen).toEqual([
      '/v1/computers/c-0123456789/computer',
      '/v1/computers/c-0123456789/fs/list?path=Documents',
      '/v1/computers/c-0123456789/catalog/photocraft/install',
      '/v1/health',
      '/v1/computers',
      '/v1/computers/c-0123456789/phones',
      '/v1/computer',
    ])
  })

  it('offers only the actions the state allows', () => {
    const capabilities = { restart: true }
    expect(availableActions({ state: 'parked', capabilities })).toEqual({ wake: true, park: false, restart: true })
    expect(availableActions({ state: 'running', capabilities })).toEqual({ wake: false, park: true, restart: true })
    expect(availableActions({ state: 'frozen', capabilities })).toEqual({ wake: true, park: true, restart: true })
    expect(stateLabel('frozen')).toBe('Sleeping')
    expect(availableActions({ state: 'restarting', capabilities })).toEqual({ wake: false, park: false, restart: false })
    expect(availableActions({ state: 'error', capabilities: { restart: false } })).toEqual({ wake: true, park: false, restart: false })
  })
})

describe('host surfaces', () => {
  function recording(respond: (url: string, init?: RequestInit) => Response = () => new Response('{}', { status: 200 })) {
    const seen: Array<{ url: string; method?: string; headers: Record<string, string>; body: unknown }> = []
    const client = new CabooseClient(() => 't', '', async (url, init) => {
      seen.push({ url: String(url), method: init?.method, headers: init?.headers as Record<string, string>, body: init?.body })
      return respond(String(url), init)
    })
    return { client, seen }
  }

  it('queues catalog operations on the documented routes', async () => {
    const { client, seen } = recording(() => new Response('{"accepted":true}', { status: 202 }))
    await client.catalog()
    await client.startCatalogOperation('photocraft', 'install')
    await client.startCatalogOperation('photocraft', 'update')
    await client.startCatalogOperation('flathub-org.mozilla.firefox', 'remove')
    await client.startCatalogOperation('flathub-org/odd id', 'install')
    await client.discoverCatalog()
    await client.discoverCatalog({ q: ' photo editor ', category: 'Video & Audio', offset: 40 })
    await client.catalogStorefront()
    expect(seen.map(entry => [entry.method, entry.url])).toEqual([
      ['GET', '/v1/catalog'],
      ['POST', '/v1/catalog/photocraft/install'],
      ['POST', '/v1/catalog/photocraft/update'],
      ['DELETE', '/v1/catalog/flathub-org.mozilla.firefox'],
      ['POST', '/v1/catalog/flathub-org%2Fodd%20id/install'],
      ['GET', '/v1/catalog/discover?q='],
      ['GET', '/v1/catalog/discover?q=photo+editor&category=Video+%26+Audio&offset=40'],
      ['GET', '/v1/catalog/storefront'],
    ])
  })

  it('lists, renames and trashes files by home-relative path', async () => {
    const { client, seen } = recording(url => new Response(url.includes('/list') ? '{"items":[]}' : '{}', { status: 200 }))
    expect(await client.listFiles('My Files')).toEqual([])
    await client.createFolder('My Files/New')
    await client.moveFile('a.txt', 'b.txt')
    await client.trashFile('b.txt')
    expect(seen.map(entry => [entry.method, entry.url, entry.body])).toEqual([
      ['GET', '/v1/fs/list?path=My%20Files', undefined],
      ['POST', '/v1/fs/mkdir?path=My%20Files%2FNew', undefined],
      ['POST', '/v1/fs/move?path=a.txt', JSON.stringify({ destination: 'b.txt' })],
      ['DELETE', '/v1/fs/item?path=b.txt', undefined],
    ])
    expect(seen.every(entry => entry.headers.Authorization === 'Bearer t')).toBe(true)
  })

  it('uploads without replacing: a taken name becomes a numbered copy', async () => {
    const taken = new Set(['Downloads/photo.png', 'Downloads/photo (2).png'])
    const { client, seen } = recording(url => {
      const path = decodeURIComponent(url.split('path=')[1]!)
      return taken.has(path) ? new Response('{"error":"version mismatch"}', { status: 412 }) : new Response('{}', { status: 201 })
    })
    const saved = await client.uploadFile('Downloads', 'photo.png', new Blob(['x'], { type: 'image/png' }))
    expect(saved).toBe('Downloads/photo (3).png')
    expect(seen.map(entry => entry.url)).toEqual([
      '/v1/fs/content?path=Downloads%2Fphoto.png',
      '/v1/fs/content?path=Downloads%2Fphoto%20(2).png',
      '/v1/fs/content?path=Downloads%2Fphoto%20(3).png',
    ])
    expect(seen[0]!.method).toBe('PUT')
    expect(seen[0]!.headers['If-None-Match']).toBe('*')
    expect(seen[0]!.headers['Content-Type']).toBe('image/png')
  })

  it('downloads bytes and reports a missing file with the host error', async () => {
    const { client } = recording(url => url.includes('gone')
      ? new Response('{"error":"not found"}', { status: 404 })
      : new Response(new Uint8Array([1, 2, 3]), { status: 200 }))
    const response = await client.downloadFile('a.bin')
    expect(new Uint8Array(await response.arrayBuffer())).toEqual(new Uint8Array([1, 2, 3]))
    const failure = await client.downloadFile('gone.bin').catch(error => error)
    expect(failure).toBeInstanceOf(CabooseApiError)
    expect(failure.status).toBe(404)
    expect(failure.message).toBe('not found')
  })

  it('treats a file permission denial as an error, not a stale token', async () => {
    const { client } = recording(() => new Response('{"error":"access denied"}', { status: 403 }))
    const failure = await client.listFiles('root-only').catch(error => error)
    expect(failure.status).toBe(403)
    expect(failure.isUnauthorized).toBe(false)
  })

  it('lists push devices and removes one by fingerprint, and reads the host description', async () => {
    const { client, seen } = recording()
    await client.pushDevices()
    await client.removePushDevice('0123456789abcdef')
    await client.host()
    await client.health()
    expect(seen.map(entry => [entry.method, entry.url])).toEqual([
      ['GET', '/v1/devices/push'],
      ['DELETE', '/v1/devices/push/0123456789abcdef'],
      ['GET', '/v1/host'],
      ['GET', '/v1/health'],
    ])
  })
})


describe('ownership requests', () => {
  it('sends people CRUD and an atomic tenant/person assignment to host routes', async () => {
    const seen: Array<{ url: string; method: string; body: unknown }> = []
    const client = new CabooseClient(() => '', '', async (url, init) => {
      seen.push({ url: String(url), method: init?.method ?? '', body: init?.body ? JSON.parse(String(init.body)) : null })
      return new Response('{}')
    }).forComputer('computer')
    await client.people('tenant')
    await client.createPerson('tenant', 'Sam')
    await client.renamePerson('person', 'Samuel')
    await client.deletePerson('person')
    await client.updateComputer('computer', { tenantId: 'destination', personId: 'person' })
    await client.setupLink()
    expect(seen).toEqual([
      { url: '/v1/tenants/tenant/people', method: 'GET', body: null },
      { url: '/v1/tenants/tenant/people', method: 'POST', body: { name: 'Sam' } },
      { url: '/v1/people/person', method: 'PATCH', body: { name: 'Samuel' } },
      { url: '/v1/people/person', method: 'DELETE', body: null },
      { url: '/v1/computers/computer', method: 'PATCH', body: { tenantId: 'destination', personId: 'person' } },
      { url: '/v1/setup/link', method: 'POST', body: null },
    ])
  })
})
