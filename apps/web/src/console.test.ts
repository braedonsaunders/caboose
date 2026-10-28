import { describe, expect, it } from 'vitest'
import {
  CabooseApiError, CabooseClient, DEFAULT_LIMITS, agentLabel, alwaysAllowOption, buildIosPairingUrl, canReply, computeSettingsPatch, hasUpdate,
  orderAgents, readSessionToken, type AgentListing,
  validateSettingsInput, willRequireColdRestart, writeSessionToken, type ComputerSettings,
} from './api.js'
import { normalizePathname } from './navigation.js'
import { availableActions, idleChoices, memoryChoices } from './state.js'

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
    expect(computeSettingsPatch(settings, { ...settings, defaultAgent: 'goose' })).toEqual({ defaultAgent: 'goose' })
    expect(computeSettingsPatch({ ...settings, defaultAgent: 'goose' }, { ...settings, defaultAgent: null })).toEqual({ defaultAgent: null })
    expect(computeSettingsPatch({ ...settings, defaultAgent: 'goose' }, { ...settings, defaultAgent: 'goose' })).toEqual({})
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

  it('builds the caboose:// pairing link the iOS app parses', () => {
    expect(buildIosPairingUrl('https://computer.example.com/', 'a b')).toBe(
      'caboose://connect?host=https%3A%2F%2Fcomputer.example.com&token=a+b')
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

describe('agent tasks', () => {
  function recording() {
    const seen: Array<{ url: string; method?: string; body: unknown }> = []
    const client = new CabooseClient(() => 't', '', async (url, init) => {
      seen.push({ url: String(url), method: init?.method, body: init?.body ? JSON.parse(String(init.body)) : undefined })
      return new Response('{"task":{},"resolved":true,"id":"x"}', { status: 200 })
    })
    return { client, seen }
  }

  it('replies to a finished task', async () => {
    const { client, seen } = recording()
    await client.replyToAgentTask('11111111-1111-4111-8111-111111111111', 'and now the tests')
    expect(seen[0]).toEqual({ url: '/v1/agent/tasks/11111111-1111-4111-8111-111111111111/reply', method: 'POST', body: { prompt: 'and now the tests' } })
    expect(canReply({ status: 'succeeded' })).toBe(true)
    expect(canReply({ status: 'cancelled' })).toBe(true)
    expect(canReply({ status: 'running' })).toBe(false)
    expect(canReply({ status: 'paused' })).toBe(false)
  })

  it('answers an approval request, with a reason or a chosen option only when given', async () => {
    const { client, seen } = recording()
    await client.resolveAgentApproval('task', 'req', true)
    await client.resolveAgentApproval('task', 'req', false, { message: '  not that file  ' })
    await client.resolveAgentApproval('task', 'req', true, { optionId: 'always' })
    expect(seen.map(entry => [entry.url, entry.body])).toEqual([
      ['/v1/agent/tasks/task/approvals/req', { allow: true }],
      ['/v1/agent/tasks/task/approvals/req', { allow: false, message: 'not that file' }],
      ['/v1/agent/tasks/task/approvals/req', { allow: true, optionId: 'always' }],
    ])
    expect(alwaysAllowOption({ id: 'r', tool: 't', summary: 's', options: [{ id: 'once', name: 'Allow', kind: 'allow_once' }, { id: 'always', name: 'Always', kind: 'allow_always' }] }))
      .toEqual({ id: 'always', name: 'Always', kind: 'allow_always' })
    expect(alwaysAllowOption({ id: 'r', tool: 't', summary: 's' })).toBeUndefined()
  })

  it('asks before acting for any agent, and leaves the agent to the host when none is chosen', async () => {
    const { client, seen } = recording()
    await client.startAgentTask({ prompt: 'p', agent: 'goose', approvals: 'ask' })
    await client.startAgentTask({ prompt: 'p', approvals: 'auto', attachments: [{ name: 'a.png', type: 'image/png', data: 'aGk=' }] })
    expect(seen.map(entry => entry.body)).toEqual([
      { prompt: 'p', agent: 'goose', approvals: 'ask' },
      { prompt: 'p', attachments: [{ name: 'a.png', type: 'image/png', data: 'aGk=' }] },
    ])
  })

  it('lists, installs and signs in to registry agents', async () => {
    const { client, seen } = recording()
    await client.agents()
    await client.installAgent('codex-acp')
    await client.signInAgent('codex-acp', 'chat-gpt')
    expect(seen.map(entry => [entry.method, entry.url, entry.body])).toEqual([
      ['GET', '/v1/agents', undefined],
      ['POST', '/v1/agents/codex-acp/install', undefined],
      ['POST', '/v1/agents/codex-acp/sign-in', { methodId: 'chat-gpt' }],
    ])
  })

  it('orders agents installed first and names them', () => {
    const agent = (id: string, installed: string | null, version = '1.0.0'): AgentListing => ({
      id, name: id.toUpperCase(), version, description: '', icon: null, website: null, repository: null, license: null, distribution: 'npx',
      installed: installed ? { version: installed } : null,
    })
    const agents = [agent('a', null), agent('b', '1.0.0'), agent('c', null), agent('d', '0.9.0')]
    expect(orderAgents(agents, 'c').map(item => item.id)).toEqual(['c', 'b', 'd', 'a'])
    expect(orderAgents(agents, null).map(item => item.id)).toEqual(['b', 'd', 'a', 'c'])
    expect(agents.filter(hasUpdate).map(item => item.id)).toEqual(['d'])
    expect(agentLabel({ agent: 'b', agentName: 'Bee' })).toBe('Bee')
    expect(agentLabel({ agent: 'b' }, agents)).toBe('B')
    expect(agentLabel({ agent: 'claude' })).toBe('claude')
  })
})

describe('navigation and actions', () => {
  it('maps any path onto a page, so SPA fallbacks land somewhere real', () => {
    expect(normalizePathname('/settings/')).toBe('/settings')
    expect(normalizePathname('/agents/abc')).toBe('/agents')
    expect(normalizePathname('/files?path=Documents')).toBe('/files')
    expect(normalizePathname('/apps/')).toBe('/apps')
    expect(normalizePathname('/devices')).toBe('/devices')
    expect(normalizePathname('/system/x')).toBe('/system')
    expect(normalizePathname('/filesystem')).toBe('/')
    expect(normalizePathname('/nope')).toBe('/')
  })

  it('offers only the actions the state allows', () => {
    const capabilities = { restart: true }
    expect(availableActions({ state: 'parked', capabilities })).toEqual({ wake: true, park: false, restart: true })
    expect(availableActions({ state: 'running', capabilities })).toEqual({ wake: false, park: true, restart: true })
    expect(availableActions({ state: 'restarting', capabilities })).toEqual({ wake: false, park: false, restart: false })
    expect(availableActions({ state: 'error', capabilities: { restart: false } })).toEqual({ wake: true, park: false, restart: false })
  })
})

describe('agent environment', () => {
  it('accepts shell-style names and one-line values', async () => {
    const { envProblem } = await import('./api.js')
    expect(envProblem('OPENROUTER_API_KEY', 'sk-or-1')).toBeUndefined()
    expect(envProblem('  OPENAI_BASE_URL ', 'https://openrouter.ai/api/v1')).toBeUndefined()
    expect(envProblem('NOT A NAME', 'x')).toMatch(/variable name/)
    expect(envProblem('1KEY', 'x')).toMatch(/variable name/)
    expect(envProblem('KEY', '')).toBe('Enter a value.')
    expect(envProblem('KEY', 'two\nlines')).toMatch(/one line/)
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
    await client.startCatalogOperation('photocraft', 'rollback')
    await client.startCatalogOperation('photocraft', 'remove')
    await client.installPack('creative-studio')
    await client.apps()
    await client.launchApp('ai.storyteller.photocraft.desktop')
    expect(seen.map(entry => [entry.method, entry.url])).toEqual([
      ['GET', '/v1/catalog'],
      ['POST', '/v1/catalog/photocraft/install'],
      ['POST', '/v1/catalog/photocraft/update'],
      ['POST', '/v1/catalog/photocraft/rollback'],
      ['DELETE', '/v1/catalog/photocraft'],
      ['POST', '/v1/catalog/packs/creative-studio/install'],
      ['GET', '/v1/apps'],
      ['POST', '/v1/apps/ai.storyteller.photocraft.desktop/launch'],
    ])
  })

  it('lists, renames, trashes and opens files by home-relative path', async () => {
    const { client, seen } = recording(url => new Response(url.includes('/list') ? '{"items":[]}' : '{}', { status: 200 }))
    expect(await client.listFiles('My Files')).toEqual([])
    await client.createFolder('My Files/New')
    await client.moveFile('a.txt', 'b.txt')
    await client.trashFile('b.txt')
    await client.openOnComputer('Documents/a b.pdf')
    expect(seen.map(entry => [entry.method, entry.url, entry.body])).toEqual([
      ['GET', '/v1/fs/list?path=My%20Files', undefined],
      ['POST', '/v1/fs/mkdir?path=My%20Files%2FNew', undefined],
      ['POST', '/v1/fs/move?path=a.txt', JSON.stringify({ destination: 'b.txt' })],
      ['DELETE', '/v1/fs/item?path=b.txt', undefined],
      ['POST', '/v1/fs/open', JSON.stringify({ path: 'Documents/a b.pdf' })],
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
