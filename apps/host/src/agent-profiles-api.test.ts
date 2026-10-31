import { once } from 'node:events'
import { mkdtemp, rm } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import type { AddressInfo } from 'node:net'
import { afterEach, expect, it, vi } from 'vitest'
import { AgentProfiles, profileContext } from './agent-profiles.js'
import { AgentIdentityError } from './agents.js'
import { createCabooseServer, defaultIdentity, type ComputerPieces, type Controller } from './server.js'
import { SettingsStore, settingsLimits } from './settings.js'
import { ComputerRegistry, PhoneTokens } from './computers.js'

const cleanups: Array<() => Promise<void>> = []
afterEach(async () => { for (const cleanup of cleanups.splice(0).reverse()) await cleanup() })

it('manages durable profile memory while parked and isolates phone access to its computer', async () => {
  const root = await mkdtemp(join(tmpdir(), 'caboose-profile-api-'))
  cleanups.push(() => rm(root, { recursive: true, force: true }))
  const computers = await ComputerRegistry.open(root)
  const second = await computers.create()
  const phones = PhoneTokens.memory()
  const wake = vi.fn(async () => { throw new Error('Profile management must not wake the guest') })
  const controller: Controller = {
    wake, park: async () => {}, activeResources: () => null, hasSavedState: () => false,
    stats: () => ({}), apps: async () => [], launch: async () => {},
    displayUrl: 'ws://127.0.0.1:1', agentDisplayUrl: 'ws://127.0.0.1:1',
    ensureAgentSeat: async () => {}, guest: () => undefined,
  }
  const defaults = { name: 'Test', memoryMb: 2048, vcpus: 2, idleMs: 60_000, defaultAgent: null }
  async function open(id: string): Promise<ComputerPieces> {
    return {
      controller,
      settings: new SettingsStore(defaults, settingsLimits(), { load: async () => undefined, save: async () => {} }),
      profiles: await AgentProfiles.open(join(computers.dataDir(id), 'agent-profiles.json')),
    }
  }
  const owner = await open('owner')
  const other = await open(second.id)
  const app = createCabooseServer({ token: 'owner-token', ...owner,
    fleet: { computers, phones, defaults, maxRunning: null, open: record => open(record.id), existing: [{ record: second, pieces: other }] },
  })
  app.server.listen(0, '127.0.0.1')
  await once(app.server, 'listening')
  cleanups.push(() => app.shutdown())
  const base = `http://127.0.0.1:${(app.server.address() as AddressInfo).port}`
  const call = (path: string, method = 'GET', body?: unknown, token = 'owner-token') => fetch(base + path, {
    method, headers: { authorization: `Bearer ${token}`, 'content-type': 'application/json' },
    ...(body === undefined ? {} : { body: JSON.stringify(body) }),
  })
  expect((await call('/v1/agent/profiles', 'GET', undefined, 'wrong')).status).toBe(401)
  const created = await call('/v1/agent/profiles', 'POST', { name: 'Planner', agent: 'codex-acp' })
  expect(created.status).toBe(201)
  const { profile } = await created.json() as { profile: { id: string } }
  expect((await call(`/v1/agent/profiles/${profile.id}/memories`, 'POST', { title: 'Timezone', content: 'America/Toronto' })).status).toBe(200)
  expect(await (await call(`/v1/computers/${second.id}/agent/profiles`)).json()).toEqual({ profiles: [] })
  expect((await call(`/v1/computers/${second.id}/agent/profiles/${profile.id}`)).status).toBe(404)
  const phone = await phones.mint(second.id, 'Other phone')
  expect(await (await call('/v1/agent/profiles', 'GET', undefined, phone.token)).json()).toEqual({ profiles: [] })
  expect((await call(`/v1/agent/profiles/${profile.id}`, 'GET', undefined, phone.token)).status).toBe(404)
  expect((await call('/v1/computers/owner/agent/profiles', 'GET', undefined, phone.token)).status).toBe(403)
  expect((await call(`/v1/agent/profiles/${profile.id}`, 'PATCH', { workspace: '/etc' })).status).toBe(400)
  expect((await call('/v1/agent/tasks', 'POST', { prompt: 'Override', workspace: '/etc' })).status).toBe(400)
  expect((await call(`/v1/agent/profiles/${profile.id}`, 'PATCH', { archived: true })).status).toBe(200)
  expect((await call('/v1/agent/tasks', 'POST', { profileId: profile.id, prompt: 'Must not run' })).status).toBe(409)
  const saved = await AgentProfiles.open(join(root, 'agent-profiles.json'))
  expect(saved.get(profile.id).memories).toMatchObject([{ title: 'Timezone', content: 'America/Toronto' }])
  expect(wake).not.toHaveBeenCalled()
})

it('resolves ordinary chats to the visible default identity and requires restoring an archived one', async () => {
  const root = await mkdtemp(join(tmpdir(), 'caboose-default-identity-'))
  cleanups.push(() => rm(root, { recursive: true, force: true }))
  const profiles = await AgentProfiles.open(join(root, 'agent-profiles.json'))
  const changed = vi.fn()
  const resolve = defaultIdentity(profiles, changed)
  const [first, second] = await Promise.all([resolve('codex-acp', 'Codex'), resolve('codex-acp', 'Codex')])
  expect(first).toEqual(second)
  expect(changed).toHaveBeenCalledTimes(1)
  const [profile] = profiles.list()
  expect(first).toEqual({ id: profile!.id, instructions: profileContext(profile!) })
  expect(first.instructions).toContain('routine tools')
  await profiles.update(profile!.id, { archived: true })
  await expect(resolve('codex-acp', 'Codex')).rejects.toThrow(AgentIdentityError)
  await expect(resolve('codex-acp', 'Codex')).rejects.toThrow('Restore it')
  expect(profiles.list(true)).toHaveLength(1)
})
