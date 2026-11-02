import { once } from 'node:events'
import type { AddressInfo } from 'node:net'
import { afterEach, expect, it, vi } from 'vitest'
import { createCabooseServer, type Controller } from './server.js'
import { SettingsStore, settingsLimits } from './settings.js'

vi.mock('./components.js', async importOriginal => ({
  ...await importOriginal<typeof import('./components.js')>(),
  upgradeComponents: async (_guest: unknown, _mode: unknown, publish: (value: unknown) => void) => publish({ state: 'succeeded', version: 'test' }),
}))
const cleanup: Array<() => Promise<void>> = []
afterEach(async () => { for (const close of cleanup.splice(0)) await close() })
async function fixture(prepareKeyring: () => Promise<void>, keyringWaitMs?: number) {
  const session = { state: 'running', display: { path: '/v1/display', token: 'test', protocol: 'caboose-display' as const }, computer: { name: 'Test', image: 'Debian', memoryMb: 2048, vcpus: 2 } }
  const launch = vi.fn(async () => {})
  const controller: Controller = {
    componentsMode: 'vm', wake: async () => session, restart: async () => session, park: async () => {},
    activeResources: () => null, hasSavedState: () => false, stats: () => ({}), apps: async () => [], launch,
    displayUrl: '', agentDisplayUrl: '', ensureAgentSeat: async () => {}, guest: () => ({ run: async () => '' }),
  }
  const settings = new SettingsStore({ name: 'Test', memoryMb: 2048, vcpus: 2, idleMs: 60000, defaultAgent: null }, settingsLimits(), { load: async () => undefined, save: async () => {} })
  const app = createCabooseServer({ token: 'owner', settings, controller, prepareKeyring, ...(keyringWaitMs ? { keyringWaitMs } : {}) })
  app.server.listen(0, '127.0.0.1'); await once(app.server, 'listening')
  cleanup.push(() => app.shutdown())
  const base = `http://127.0.0.1:${(app.server.address() as AddressInfo).port}`
  const request = (path: string, method = 'GET') => fetch(base + path, { method, headers: { authorization: 'Bearer owner' } })
  await request('/v1/session', 'POST')
  return { app, launch, request }
}
it('waits for preparation before launching an application', async () => {
  let finish!: () => void
  const gate = new Promise<void>(resolve => { finish = resolve })
  const prepare = vi.fn(() => gate)
  const { launch, request } = await fixture(prepare)
  await vi.waitFor(() => expect(prepare).toHaveBeenCalledOnce())
  expect((await (await request('/v1/computer')).json()).keyring.state).toBe('preparing')
  const pending = request('/v1/apps/chromium.desktop/launch', 'POST')
  await new Promise(resolve => setTimeout(resolve, 25))
  expect(launch).not.toHaveBeenCalled()
  finish()
  expect((await pending).status).toBe(200)
  expect(launch).toHaveBeenCalledOnce()
  expect((await (await request('/v1/computer')).json()).keyring).toEqual({ state: 'ready' })
})
it('reports a failed preparation instead of launching, after trying it once more', async () => {
  const prepare = vi.fn(async () => { throw new Error('Original keyring password required') })
  const { launch, request } = await fixture(prepare)
  await vi.waitFor(async () => expect((await (await request('/v1/computer')).json()).keyring.state).toBe('failed'))
  const response = await request('/v1/apps/chromium.desktop/launch', 'POST')
  expect(response.status).toBe(409)
  expect(JSON.stringify(await response.json())).toContain('Original keyring password required')
  expect(prepare).toHaveBeenCalledTimes(2)
  expect(launch).not.toHaveBeenCalled()
})
it('launches once a failed preparation succeeds on the retry', async () => {
  const prepare = vi.fn().mockRejectedValueOnce(new Error('Secret Service not running')).mockResolvedValue(undefined)
  const { launch, request } = await fixture(prepare)
  await vi.waitFor(async () => expect((await (await request('/v1/computer')).json()).keyring.state).toBe('failed'))
  expect((await request('/v1/apps/chromium.desktop/launch', 'POST')).status).toBe(200)
  expect(launch).toHaveBeenCalledOnce()
  expect((await (await request('/v1/computer')).json()).keyring).toEqual({ state: 'ready' })
})
it('refuses a launch when preparation outlasts the wait', async () => {
  let finish!: () => void
  const prepare = vi.fn(() => new Promise<void>(resolve => { finish = resolve }))
  const { launch, request } = await fixture(prepare, 50)
  await vi.waitFor(() => expect(prepare).toHaveBeenCalledOnce())
  const response = await request('/v1/apps/chromium.desktop/launch', 'POST')
  expect(response.status).toBe(409)
  expect(launch).not.toHaveBeenCalled()
  finish()
})
it('does not publish an old preparation result after a run generation changes', async () => {
  let finish!: () => void
  const gate = new Promise<void>(resolve => { finish = resolve })
  const prepare = vi.fn(() => gate)
  const { app, request } = await fixture(prepare)
  await vi.waitFor(() => expect(prepare).toHaveBeenCalledOnce())
  // Direct lifecycle restart models a transport/run replacement while work is outstanding.
  await app.computer.restart()
  finish()
  await new Promise(resolve => setTimeout(resolve, 25))
  expect((await (await request('/v1/computer')).json()).keyring).toBeNull()
})
