import { once } from 'node:events'
import { mkdtemp, readFile, rm } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import type { AddressInfo } from 'node:net'
import { afterEach, expect, it, vi } from 'vitest'
import { AgentProfiles } from './agent-profiles.js'
import { AgentRoutines } from './agent-routines.js'
import { AgentRegistry } from './registry.js'
import { createCabooseServer, type Controller } from './server.js'
import { SettingsStore, settingsLimits } from './settings.js'

const cleanup: Array<() => Promise<void>> = []
afterEach(async () => { for (const close of cleanup.splice(0).reverse()) await close() })

it('reserves via authenticated HTTP while parked and wakes without a phone to admit the exact profile task', async () => {
  const root = await mkdtemp(join(tmpdir(), 'caboose-routines-api-'))
  cleanup.push(() => rm(root, { recursive: true, force: true }))
  const profiles = await AgentProfiles.open(join(root, 'profiles.json'))
  const profile = await profiles.create({ name: 'Research', agent: 'claude-acp', instructions: 'Use primary sources.' })
  const commands: string[][] = []
  const guest = { run: async (command: string, args: string[]) => { commands.push([command, ...args]); return command === '/usr/bin/python3' && args[2] === 'list' ? '{}' : '' } }
  const wake = vi.fn(async () => ({ state: 'running', display: { path: '/v1/display', token: 'unused', protocol: 'caboose-display' as const }, computer: { name: 'Test', image: 'Debian', memoryMb: 2048, vcpus: 2 } }))
  const controller: Controller = { wake, park: async () => {}, activeResources: () => null, hasSavedState: () => false,
    stats: () => ({}), apps: async () => [], launch: async () => {}, displayUrl: 'ws://127.0.0.1:1', agentDisplayUrl: 'ws://127.0.0.1:1', ensureAgentSeat: async () => {}, guest: () => guest }
  const settings = new SettingsStore({ name: 'Test', memoryMb: 2048, vcpus: 2, idleMs: 60_000, defaultAgent: null }, settingsLimits(), { load: async () => undefined, save: async () => {} })
  const registry = new AgentRegistry({ fetch: (async () => new Response(await readFile(new URL('./fixtures/acp-registry.json', import.meta.url)))) as unknown as typeof fetch })
  let routines!: AgentRoutines
  const app = createCabooseServer({ token: 'owner', settings, controller, profiles, registry,
    openRoutines: async options => {
      routines = await AgentRoutines.open(join(root, 'routines.json'), { ...options,
        clock: { now: () => Date.parse('2026-10-28T12:00:00Z'), setTimeout: () => 1, clearTimeout: () => {} } })
      return routines
    },
  })
  app.server.listen(0, '127.0.0.1'); await once(app.server, 'listening'); cleanup.push(() => app.shutdown())
  const base = `http://127.0.0.1:${(app.server.address() as AddressInfo).port}`
  const call = (path: string, method = 'GET', body?: unknown, token = 'owner') => fetch(base + path, {
    method, headers: { authorization: `Bearer ${token}`, 'content-type': 'application/json' }, ...(body === undefined ? {} : { body: JSON.stringify(body) }),
  })
  expect((await call('/v1/agent/routines', 'GET', undefined, 'invalid')).status).toBe(401)
  const response = await call('/v1/agent/routines', 'POST', { name: 'Daily report', profileId: profile.id, prompt: 'Summarize the news', schedule: { kind: 'daily', timeZone: 'America/Toronto', time: '09:00' } })
  expect(response.status).toBe(201)
  const { routine } = await response.json() as { routine: { id: string } }
  expect(wake).not.toHaveBeenCalled()
  const accepted = await call(`/v1/agent/routines/${routine.id}/run`, 'POST', {})
  expect(accepted.status).toBe(202)
  const { run } = await accepted.json() as { run: { id: string; input: object } }
  expect(run.input).toEqual({}); expect(wake).not.toHaveBeenCalled()
  await routines.tick()
  expect(wake).toHaveBeenCalledTimes(1)
  const tasks = await (await call('/v1/agent/tasks')).json() as Array<{ id: string; profileId: string; approvals: string }>
  expect(tasks).toMatchObject([{ id: run.id, profileId: profile.id, approvals: 'ask' }])
  expect(commands.some(args => args.some(arg => arg.includes('AgentWorkspaces/' + profile.id)))).toBe(true)
  const history = await (await call(`/v1/agent/routines/${routine.id}/history`)).json()
  expect(history).toMatchObject({ runs: [{ id: run.id, status: 'active', input: {} }] })
  expect((await call(`/v1/agent/routines/${routine.id}/run`, 'POST', {})).status).toBe(409)
  expect((await call(`/v1/agent/routines/${routine.id}`, 'PATCH', { paused: true })).status).toBe(200)
  expect((await call(`/v1/agent/routines/${routine.id}`, 'DELETE')).status).toBe(200)
  expect(await (await call('/v1/agent/routines')).json()).toMatchObject({ routines: [] })
})
