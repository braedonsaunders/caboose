import { once } from 'node:events'
import { readFile } from 'node:fs/promises'
import type { AddressInfo } from 'node:net'
import { afterEach, describe, expect, it, vi } from 'vitest'
import { HOME_REPAIR_SCRIPT, type HomeOwnership } from './home.js'
import { AgentCatalog, parseGuestState, publicSignIn } from './agent-catalog.js'
import { AGENTD, AgentConflictError, AgentInputError, AgentNotFoundError, AgentOperationError, type AgentGuest } from './agents.js'
import { AgentRegistry, type AgentLaunch } from './registry.js'
import { createCabooseServer, type Controller } from './server.js'
import { SettingsInputError, SettingsStore, settingsLimits } from './settings.js'

const fixture = JSON.parse(await readFile(new URL('./fixtures/acp-registry.json', import.meta.url), 'utf8')) as { agents: unknown[] }
const cleanup: Array<() => Promise<void>> = []
afterEach(async () => { for (const step of cleanup.splice(0).reverse()) await step() })

const decode = (value: string) => JSON.parse(Buffer.from(value, 'base64').toString('utf8'))
const CLAUDE_METHODS = [
  { id: 'claude-ai-login', name: 'Claude Subscription', description: 'Use Claude subscription ', type: 'terminal', args: ['--cli', 'auth', 'login', '--claudeai'] },
  { id: 'console-login', name: 'Anthropic Console', type: 'terminal', args: ['--cli', 'auth', 'login', '--console'] },
]

/** A guest whose caboose-agentd keeps its state in memory. */
function fakeGuest(options: { missing?: boolean; failInstall?: string } = {}) {
  const agents: Record<string, Record<string, unknown>> = {}
  const calls: Array<{ mode: string; argument?: unknown }> = []
  const methods: Record<string, unknown[]> = { 'claude-acp': CLAUDE_METHODS, 'codex-acp': [{ id: 'chat-gpt', name: 'ChatGPT', description: 'Use ChatGPT to authenticate' }] }
  const guest: AgentGuest = {
    async run(command, args) {
      if (command === '/bin/sh' && args[1] === HOME_REPAIR_SCRIPT) return '0'
      expect(command).toBe('/usr/sbin/runuser')
      expect(args.slice(0, 6)).toEqual(['-u', 'caboose', '--', '/usr/bin/env', 'HOME=/home/caboose', 'PATH=/home/caboose/.local/bin:/usr/local/bin:/usr/bin:/bin'])
      if (options.missing) throw new Error('Guest command failed: caboose-agentd is not installed in this computer')
      const at = args.indexOf(AGENTD)
      const script = args[at - 2]!
      if (script.includes('sign-in')) {
        calls.push({ mode: 'sign-in', argument: decode(args[at + 1]!) })
        return ''
      }
      const mode = args[at + 1]!
      if (mode === 'set-env') {
        const [id, json] = [args[at + 2]!, JSON.parse(args[at + 3]!) as { set: Record<string, string>; remove: string[] }]
        calls.push({ mode, argument: { id, ...json } })
        const names = new Set([...(agents[id]?.env as string[] ?? []), ...Object.keys(json.set)].filter(name => !json.remove.includes(name)))
        agents[id] = { ...agents[id], env: [...names].sort() }
        return JSON.stringify({ env: agents[id]!.env })
      }
      const argument = args[at + 2] ? decode(args[at + 2]!) as AgentLaunch : undefined
      calls.push({ mode, argument })
      if (mode === 'state') return JSON.stringify({ runner: '0.1.0', agents })
      if (mode === 'install') {
        if (options.failInstall) throw new Error(`Guest command failed: ${options.failInstall}`)
        agents[argument!.id] = { installed: { version: argument!.version, spec: argument, installedAt: 'now' }, authMethods: methods[argument!.id] ?? [] }
        return JSON.stringify({ installed: { version: argument!.version } })
      }
      if (mode === 'probe') {
        agents[argument!.id] = { ...agents[argument!.id], authMethods: methods[argument!.id] ?? [] }
        return '{}'
      }
      throw new Error(`unexpected ${mode}`)
    },
  }
  return { guest, agents, calls }
}

function registry() {
  const fetch = vi.fn(async () => new Response(JSON.stringify(fixture), { status: 200, headers: { etag: '"x"' } }))
  return new AgentRegistry({ fetch: fetch as unknown as typeof globalThis.fetch })
}

function settingsStore() {
  return new SettingsStore({ name: 'Caboose', memoryMb: 2048, vcpus: 2, idleMs: 600_000, defaultAgent: null }, settingsLimits(), { load: async () => undefined, save: async () => {} })
}

describe('AgentCatalog', () => {
  it('lists the registry while parked, without touching the computer', async () => {
    const settings = settingsStore()
    const catalog = new AgentCatalog(registry(), () => undefined, settings)
    const listed = await catalog.list()
    expect(listed.defaultAgent).toBeNull()
    expect(listed.registry.error).toBeUndefined()
    expect(listed.registry.fetchedAt).toEqual(expect.any(String))
    expect(listed.agents).toHaveLength(fixture.agents.length)
    expect(listed.agents.find(agent => agent.id === 'claude-acp')).toEqual({
      id: 'claude-acp', name: 'Claude Agent', version: '0.98.0', description: "ACP wrapper for Anthropic's Claude",
      icon: 'https://cdn.agentclientprotocol.com/registry/v1/latest/claude-acp.svg', website: null,
      repository: 'https://github.com/agentclientprotocol/claude-agent-acp', license: 'proprietary', distribution: 'npx', installed: null,
    })
  })

  it('installs from the registry, learns how the agent signs in, and makes the first install the default', async () => {
    const fake = fakeGuest()
    const settings = settingsStore()
    const catalog = new AgentCatalog(registry(), () => fake.guest, settings)
    const installed = await catalog.install('claude-acp')
    expect(fake.calls.find(call => call.mode === 'install')?.argument).toEqual({ id: 'claude-acp', name: 'Claude Agent', version: '0.98.0', distribution: 'npx', package: '@agentclientprotocol/claude-agent-acp@0.98.0', args: [], env: {} })
    expect(installed).toMatchObject({ id: 'claude-acp', installed: { version: '0.98.0' }, signIn: [
      { id: 'claude-ai-login', name: 'Claude Subscription', description: 'Use Claude subscription ', type: 'terminal' },
      { id: 'console-login', name: 'Anthropic Console', type: 'terminal' },
    ] })
    expect(settings.get().defaultAgent).toBe('claude-acp')
    await catalog.install('goose')
    expect(settings.get().defaultAgent).toBe('claude-acp')
    expect(fake.calls.find(call => call.mode === 'install' && (call.argument as AgentLaunch).id === 'goose')?.argument).toMatchObject({ distribution: 'binary', sha256: expect.stringMatching(/^[0-9a-f]{64}$/) })
    await expect(catalog.install('not-an-agent')).rejects.toBeInstanceOf(AgentNotFoundError)
  })

  it('gives the home back to caboose before an install or a sign-in runs npm, uv or the agent', async () => {
    const fake = fakeGuest()
    const ensure = vi.fn(async () => { fake.calls.push({ mode: 'repair' }); return 0 })
    const catalog = new AgentCatalog(registry(), () => fake.guest, settingsStore(), { ensure, reset: () => {} } as unknown as HomeOwnership)
    await catalog.install('claude-acp')
    await catalog.signIn('codex-acp', { methodId: 'chat-gpt' })
    expect(ensure).toHaveBeenCalledTimes(2)
    const modes = fake.calls.map(call => call.mode)
    expect(modes.indexOf('repair')).toBeLessThan(modes.indexOf('install'))
    expect(modes.lastIndexOf('repair')).toBeLessThan(modes.indexOf('probe'))
  })

  it('runs the installed version of an agent, and the registry\'s when none is installed', async () => {
    const fake = fakeGuest()
    const pinned = { id: 'codex-acp', name: 'Codex', version: '2.0.0', distribution: 'npx', package: '@agentclientprotocol/codex-acp@2.0.0', args: [], env: {} }
    fake.agents['codex-acp'] = { installed: { version: '2.0.0', spec: pinned } }
    fake.agents['retired'] = { installed: { version: '1.0.0', spec: { ...pinned, id: 'retired', name: 'Retired' } } }
    const catalog = new AgentCatalog(registry(), () => fake.guest, settingsStore())
    expect(await catalog.launch('codex-acp')).toEqual(pinned)
    expect((await catalog.launch('claude-acp')).version).toBe('0.98.0')
    await expect(catalog.launch('nope')).rejects.toThrow('"nope" is not in the agent registry')
    const listed = await catalog.list()
    // An installed agent that left the registry is still there to run.
    expect(listed.agents.at(-1)).toMatchObject({ id: 'retired', name: 'Retired', installed: { version: '1.0.0' } })
    expect(listed.agents.find(agent => agent.id === 'codex-acp')).toMatchObject({ version: '2.3.0', installed: { version: '2.0.0' } })
  })

  it('starts a sign-in on the owner display, learning the methods first when it must', async () => {
    const fake = fakeGuest()
    const catalog = new AgentCatalog(registry(), () => fake.guest, settingsStore())
    await expect(catalog.signIn('codex-acp', {})).rejects.toBeInstanceOf(AgentInputError)
    await expect(catalog.signIn('codex-acp', { methodId: 'api-key' })).rejects.toThrow('Codex has no sign-in method "api-key"')
    expect(fake.calls.filter(call => call.mode === 'probe')).toHaveLength(1)
    const started = await catalog.signIn('codex-acp', { methodId: 'chat-gpt' })
    expect(started).toEqual({ started: true, method: { id: 'chat-gpt', name: 'ChatGPT', description: 'Use ChatGPT to authenticate', type: 'agent' } })
    expect(fake.calls.filter(call => call.mode === 'probe')).toHaveLength(1)
    expect(fake.calls.at(-1)).toEqual({ mode: 'sign-in', argument: { agent: expect.objectContaining({ id: 'codex-acp', version: '2.3.0' }), methodId: 'chat-gpt', env: { DISPLAY: ':100' } } })
  })

  it('starts a sign-in with the launch environment of the display the owner sees', async () => {
    const fake = fakeGuest()
    const env = ['WAYLAND_DISPLAY=wayland-caboose-0', 'DISPLAY=:110', 'GDK_BACKEND=wayland,x11', 'QT_QPA_PLATFORM=wayland;xcb']
    const catalog = new AgentCatalog(registry(), () => ({ ...fake.guest, ownerEnv: env }), settingsStore())
    await catalog.signIn('claude-acp', { methodId: 'claude-ai-login' })
    expect(fake.calls.at(-1)).toMatchObject({ mode: 'sign-in', argument: { methodId: 'claude-ai-login',
      env: { WAYLAND_DISPLAY: 'wayland-caboose-0', DISPLAY: ':110', GDK_BACKEND: 'wayland,x11', QT_QPA_PLATFORM: 'wayland;xcb' } } })
  })

  it('accepts only agents a task could run as the default', async () => {
    const catalog = new AgentCatalog(registry(), () => undefined, settingsStore())
    await expect(catalog.ensureKnown('goose')).resolves.toBeUndefined()
    await expect(catalog.ensureKnown(null)).resolves.toBeUndefined()
    await expect(catalog.ensureKnown('nope')).rejects.toBeInstanceOf(SettingsInputError)
    await expect(catalog.ensureKnown('../x')).rejects.toBeInstanceOf(SettingsInputError)
  })

  it('explains a computer without the runner and a failed install', async () => {
    const missing = new AgentCatalog(registry(), () => fakeGuest({ missing: true }).guest, settingsStore())
    await expect(missing.install('goose')).rejects.toBeInstanceOf(AgentConflictError)
    await expect(missing.install('goose')).rejects.toThrow('guest/agentd/install.sh')
    const broken = new AgentCatalog(registry(), () => fakeGuest({ failInstall: 'goose failed verification: sha256 a is not b' }).guest, settingsStore())
    const failure = broken.install('goose')
    await expect(failure).rejects.toBeInstanceOf(AgentOperationError)
    await expect(failure).rejects.toThrow('Installing goose failed: goose failed verification')
  })

  it('reads the runner\'s state defensively', () => {
    expect(parseGuestState(JSON.stringify({ agents: {
      '../bad': { installed: { version: '1', spec: { id: '../bad' } } },
      ok: { installed: { version: '1', spec: { id: 'other' } }, authMethods: [], signInStatus: { methodId: 'm', status: 'weird' } },
    } }))).toEqual({ ok: { authMethods: [] } })
    expect(publicSignIn([{ id: 'a', name: 'A' }, { id: 'e', name: 'E', type: 'env_var' }, null])).toEqual([{ id: 'a', name: 'A', type: 'agent' }])
  })
})

describe('agent routes', () => {
  async function server() {
    const fake = fakeGuest()
    let running = false
    const controller: Controller = {
      wake: vi.fn(async () => { running = true; return { state: 'running', display: { path: '/v1/display', token: 't', protocol: 'xpra-ws' as const }, computer: { name: 'C', image: 'Debian 13', memoryMb: 2048, vcpus: 2 } } }),
      park: vi.fn(async () => { running = false }), activeResources: () => null, hasSavedState: () => false,
      stats: () => ({}), apps: async () => [], launch: async () => {},
      displayUrl: 'ws://127.0.0.1:1', agentDisplayUrl: 'ws://127.0.0.1:1', ensureAgentSeat: async () => {},
      guest: () => running ? fake.guest : undefined,
    }
    const settings = settingsStore()
    const app = createCabooseServer({ token: 'owner', settings, controller, registry: registry() })
    app.server.listen(0, '127.0.0.1')
    await once(app.server, 'listening')
    cleanup.push(() => app.shutdown())
    const base = `http://127.0.0.1:${(app.server.address() as AddressInfo).port}`
    const request = async (path: string, method = 'GET', body?: unknown) => {
      const response = await fetch(base + path, { method, headers: { authorization: 'Bearer owner', 'content-type': 'application/json' }, ...(body === undefined ? {} : { body: JSON.stringify(body) }) })
      return { status: response.status, body: await response.json() as any }
    }
    return { fake, controller, settings, request, base }
  }

  it('lists, installs, signs in and sets the default agent', async () => {
    const { request, controller, fake, base } = await server()
    expect((await fetch(`${base}/v1/agents`)).status).toBe(401)
    const listed = await request('/v1/agents')
    expect(listed.status).toBe(200)
    expect(listed.body).toMatchObject({ defaultAgent: null, registry: { fetchedAt: expect.any(String) } })
    expect(controller.wake).not.toHaveBeenCalled()
    expect((await request('/v1/agents/goose/install', 'POST')).status).toBe(409)
    expect((await request('/v1/agent/tasks', 'POST', { prompt: 'hi' })).status).toBe(409)
    await request('/v1/session', 'POST')
    expect(await request('/v1/agent/tasks', 'POST', { prompt: 'hi' })).toEqual({ status: 400, body: { error: 'Choose an agent: pass agent, or set a default agent in Settings' } })
    const installed = await request('/v1/agents/claude-acp/install', 'POST')
    expect(installed).toMatchObject({ status: 200, body: { agent: { id: 'claude-acp', installed: { version: '0.98.0' } } } })
    expect((await request('/v1/computer')).body.settings.defaultAgent).toBe('claude-acp')
    expect((await request('/v1/agents/nope/install', 'POST')).status).toBe(404)
    expect((await request('/v1/computer/settings', 'PATCH', { defaultAgent: 'nope' })).status).toBe(400)
    expect((await request('/v1/computer/settings', 'PATCH', { defaultAgent: 'goose' })).body.settings.defaultAgent).toBe('goose')
    expect((await request('/v1/computer/settings', 'PATCH', { defaultAgent: null })).body.settings.defaultAgent).toBeNull()
    expect(await request('/v1/agents/claude-acp/sign-in', 'POST', { methodId: 'console-login' })).toEqual({ status: 200, body: { started: true, method: { id: 'console-login', name: 'Anthropic Console', type: 'terminal' } } })
    expect(fake.calls.at(-1)?.mode).toBe('sign-in')
    expect((await request('/v1/agents/claude-acp/sign-in', 'POST', { methodId: 'nope' })).status).toBe(400)
    const after = await request('/v1/agents')
    expect(after.body.agents.find((agent: { id: string }) => agent.id === 'claude-acp')).toMatchObject({ installed: { version: '0.98.0' }, signIn: [{ id: 'claude-ai-login' }, { id: 'console-login' }] })
  })

  it('sets and removes an agent\'s environment variables in the computer, listing names only', async () => {
    const fake = fakeGuest()
    const catalog = new AgentCatalog(registry(), () => fake.guest, settingsStore())
    expect(await catalog.setEnv('codex-acp', { set: { OPENAI_API_KEY: 'sk-1', OPENAI_BASE_URL: 'https://openrouter.ai/api/v1' } }))
      .toEqual({ env: ['OPENAI_API_KEY', 'OPENAI_BASE_URL'] })
    expect(fake.calls.at(-1)).toEqual({ mode: 'set-env', argument: { id: 'codex-acp', set: { OPENAI_API_KEY: 'sk-1', OPENAI_BASE_URL: 'https://openrouter.ai/api/v1' }, remove: [] } })
    const listed = (await catalog.list()).agents.find(agent => agent.id === 'codex-acp')!
    expect(listed.env).toEqual(['OPENAI_API_KEY', 'OPENAI_BASE_URL'])
    expect(JSON.stringify(await catalog.list())).not.toContain('sk-1')
    expect(await catalog.setEnv('codex-acp', { remove: ['OPENAI_BASE_URL'] })).toEqual({ env: ['OPENAI_API_KEY'] })
    await expect(catalog.setEnv('codex-acp', { set: { 'NOT A NAME': 'x' } })).rejects.toThrow('is not a variable name')
    await expect(catalog.setEnv('codex-acp', { set: { KEY: 'a\nb' } })).rejects.toThrow('one line')
    await expect(catalog.setEnv('codex-acp', {})).rejects.toThrow('Nothing to change')
    await expect(catalog.setEnv('codex-acp', { values: {} })).rejects.toThrow('Unknown field')
    await expect(catalog.setEnv('../x', { remove: ['A'] })).rejects.toThrow('agent not found')
    await expect(new AgentCatalog(registry(), () => undefined, settingsStore()).setEnv('codex-acp', { remove: ['A'] })).rejects.toThrow('not running')
  })
})
