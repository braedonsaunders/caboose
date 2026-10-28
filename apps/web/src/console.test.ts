import { describe, expect, it } from 'vitest'
import {
  CabooseApiError, CabooseClient, DEFAULT_LIMITS, buildIosPairingUrl, canAskFirst, canReply, computeSettingsPatch, readSessionToken,
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

  it('answers an approval request, with a reason only when given', async () => {
    const { client, seen } = recording()
    await client.resolveAgentApproval('task', 'req', true)
    await client.resolveAgentApproval('task', 'req', false, '  not that file  ')
    expect(seen.map(entry => [entry.url, entry.body])).toEqual([
      ['/v1/agent/tasks/task/approvals/req', { allow: true }],
      ['/v1/agent/tasks/task/approvals/req', { allow: false, message: 'not that file' }],
    ])
  })

  it('asks before acting only for Claude Code', async () => {
    const { client, seen } = recording()
    await client.startAgentTask({ prompt: 'p', agent: 'claude', approvals: 'ask' })
    await client.startAgentTask({ prompt: 'p', agent: 'codex', approvals: 'ask' })
    await client.startAgentTask({ prompt: 'p', agent: 'claude', approvals: 'auto', attachments: [{ name: 'a.png', type: 'image/png', data: 'aGk=' }] })
    expect(seen.map(entry => entry.body)).toEqual([
      { prompt: 'p', agent: 'claude', approvals: 'ask' },
      { prompt: 'p', agent: 'codex' },
      { prompt: 'p', agent: 'claude', attachments: [{ name: 'a.png', type: 'image/png', data: 'aGk=' }] },
    ])
    expect(canAskFirst('claude')).toBe(true)
    expect(canAskFirst('codex')).toBe(false)
  })
})

describe('navigation and actions', () => {
  it('maps any path onto a page, so SPA fallbacks land somewhere real', () => {
    expect(normalizePathname('/settings/')).toBe('/settings')
    expect(normalizePathname('/agents/abc')).toBe('/agents')
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
