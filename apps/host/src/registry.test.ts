import { mkdtemp, readFile, rm, stat } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { afterEach, describe, expect, it, vi } from 'vitest'
import { AgentRegistry, parseRegistry, resolveLaunch } from './registry.js'

/** registry.json as published on 2026-10-28, kept as a test fixture. */
const fixture = JSON.parse(await readFile(new URL('./fixtures/acp-registry.json', import.meta.url), 'utf8')) as { agents: Array<Record<string, any>> }
const roots: string[] = []
afterEach(async () => { for (const root of roots.splice(0)) await rm(root, { recursive: true, force: true }) })

describe('parseRegistry', () => {
  const agents = parseRegistry(fixture)
  const byId = new Map(agents.map(agent => [agent.id, agent]))

  it('reads every published agent with the fields clients show', () => {
    expect(agents).toHaveLength(fixture.agents.length)
    expect(byId.get('codex-acp')).toMatchObject({
      name: 'Codex', version: '2.3.0', description: "ACP adapter for OpenAI's coding assistant", license: 'Apache-2.0',
      icon: 'https://cdn.agentclientprotocol.com/registry/v1/latest/codex-acp.svg',
      repository: 'https://github.com/agentclientprotocol/codex-acp', website: null,
    })
  })

  it('resolves npx, uvx and binary distributions for linux-x86_64', () => {
    expect(byId.get('claude-acp')?.launch).toEqual({ id: 'claude-acp', name: 'Claude Agent', version: '0.98.0', distribution: 'npx', package: '@agentclientprotocol/claude-agent-acp@0.98.0', args: [], env: {} })
    expect(byId.get('fast-agent')?.launch).toEqual({ id: 'fast-agent', name: 'fast-agent', version: '0.10.1', distribution: 'uvx', package: 'fast-agent-acp==0.10.1', args: ['-x'], env: { FAST_AGENT_MODEL: 'codexplan' } })
    expect(byId.get('goose')?.launch).toEqual({
      id: 'goose', name: 'goose', version: '1.56.0', distribution: 'binary',
      archive: 'https://github.com/block/goose/releases/download/v1.56.0/goose-x86_64-unknown-linux-gnu.tar.bz2',
      sha256: 'e29544421a6e698aab0fe4becda96096218ff36abe85b83785519d41c555c714', cmd: './goose', args: ['acp'], env: {},
    })
  })

  it('prefers a checksummed binary, then npx, then uvx, then a binary without a checksum', () => {
    // Kilo publishes both; its binary has a checksum.
    expect(byId.get('kilo')?.launch?.distribution).toBe('binary')
    // A binary without a checksum is still offered when it is the only way, over HTTPS.
    expect(byId.get('cursor')?.launch).toMatchObject({ distribution: 'binary', cmd: './dist-package/cursor-agent', args: ['acp'] })
    expect(byId.get('cursor')?.launch?.sha256).toBeUndefined()
    const both = { id: 'x', name: 'X', version: '1.0.0', distribution: {
      binary: { 'linux-x86_64': { archive: 'https://example.com/x.tar.gz', cmd: './x' } },
      npx: { package: 'x@1.0.0' }, uvx: { package: 'x==1.0.0' },
    } }
    expect(resolveLaunch(both)?.distribution).toBe('npx')
    expect(resolveLaunch({ ...both, distribution: { ...both.distribution, npx: undefined } })?.distribution).toBe('uvx')
    expect(resolveLaunch({ ...both, distribution: { binary: both.distribution.binary } })?.distribution).toBe('binary')
  })

  it('leaves out what Caboose cannot run safely', () => {
    const odd = parseRegistry({ agents: [
      { id: 'mac-only', name: 'Mac only', version: '1.0.0', distribution: { binary: { 'darwin-aarch64': { archive: 'https://example.com/a.zip', cmd: './a' } } } },
      { id: 'plain-http', name: 'Plain', version: '1.0.0', distribution: { binary: { 'linux-x86_64': { archive: 'http://example.com/a.tgz', cmd: './a', sha256: 'a'.repeat(64) } } } },
      { id: 'escapes', name: 'Escapes', version: '1.0.0', distribution: { binary: { 'linux-x86_64': { archive: 'https://example.com/a.tgz', cmd: '../../bin/sh' } } } },
      { id: 'flag', name: 'Flag', version: '1.0.0', distribution: { npx: { package: '--registry=https://evil.example' } } },
      { id: 'bad-env', name: 'Bad env', version: '1.0.0', distribution: { npx: { package: 'a@1', env: { 'A B': 'x' } } } },
      { id: 'Upper', name: 'Bad id', version: '1.0.0', distribution: { npx: { package: 'a@1' } } },
      { id: 'no-version', name: 'No version', distribution: { npx: { package: 'a@1' } } },
      { id: 'ok', name: 'OK', version: '1.0.0', icon: 'javascript:alert(1)', distribution: { npx: { package: 'a@1' } } },
      { id: 'ok', name: 'Duplicate', version: '2.0.0', distribution: { npx: { package: 'a@2' } } },
    ] })
    expect(odd.map(agent => [agent.id, agent.launch?.distribution])).toEqual([
      ['mac-only', undefined], ['plain-http', undefined], ['escapes', undefined], ['flag', undefined], ['bad-env', undefined], ['ok', 'npx'],
    ])
    expect(odd.at(-1)?.icon).toBeNull()
    expect(() => parseRegistry({ version: '1.0.0' })).toThrow('no agents list')
  })
})

describe('AgentRegistry', () => {
  function server() {
    let now = 1_000_000
    const responses: Array<() => Response> = []
    const fetch = vi.fn(async (_url: string | URL | Request, init?: RequestInit) => {
      const next = responses.shift()
      if (!next) throw new Error('offline')
      void init
      return next()
    })
    return {
      fetch: fetch as unknown as typeof globalThis.fetch, calls: fetch, responses,
      tick: (ms: number) => { now += ms }, now: () => now,
    }
  }
  const ok = (body: unknown, etag = '"v1"') => () => new Response(JSON.stringify(body), { status: 200, headers: { etag, 'content-type': 'application/json' } })

  it('selects ARM64 binaries from the network and persisted registry cache', async () => {
    const root = await mkdtemp(join(tmpdir(), 'caboose-registry-')); roots.push(root)
    const cachePath = join(root, 'registry.json')
    const net = server()
    const agent = { id: 'test-agent', name: 'Test', version: '1.0.0', distribution: { binary: {
      'linux-x86_64': { archive: 'https://example.com/x64.tgz', cmd: './agent', sha256: 'a'.repeat(64) },
      'linux-aarch64': { archive: 'https://example.com/arm64.tgz', cmd: './agent', sha256: 'b'.repeat(64) },
    } } }
    net.responses.push(ok({ agents: [agent] }))
    const registry = new AgentRegistry({ fetch: net.fetch, platform: 'linux-aarch64', cachePath })
    expect((await registry.get('test-agent'))?.launch?.archive).toBe('https://example.com/arm64.tgz')
    const offline = new AgentRegistry({ fetch: server().fetch, platform: 'linux-aarch64', cachePath })
    expect((await offline.get('test-agent'))?.launch?.archive).toBe('https://example.com/arm64.tgz')
  })

  it('fetches once per TTL, revalidates with the ETag, and keeps the last good copy on failure', async () => {
    const root = await mkdtemp(join(tmpdir(), 'caboose-registry-')); roots.push(root)
    const cachePath = join(root, 'agent-registry.json')
    const net = server()
    const registry = new AgentRegistry({ fetch: net.fetch, now: net.now, ttlMs: 60_000, cachePath, url: 'https://registry.example/registry.json' })
    net.responses.push(ok(fixture))
    const first = await registry.catalog()
    expect(first.agents).toHaveLength(fixture.agents.length)
    expect(first.error).toBeUndefined()
    expect(first.fetchedAt).toBe(new Date(1_000_000).toISOString())
    expect(net.calls.mock.calls[0]?.[0]).toBe('https://registry.example/registry.json')
    await registry.catalog()
    expect(net.calls).toHaveBeenCalledTimes(1)
    expect((await stat(cachePath)).mode & 0o777).toBe(0o600)

    net.tick(60_000)
    net.responses.push(() => new Response(null, { status: 304 }))
    const revalidated = await registry.catalog()
    expect((net.calls.mock.calls[1]?.[1]?.headers as Record<string, string>)['if-none-match']).toBe('"v1"')
    expect(revalidated.agents).toHaveLength(fixture.agents.length)

    net.tick(60_000)
    const offline = await registry.catalog()
    expect(offline.agents).toHaveLength(fixture.agents.length)
    expect(offline.error).toBe('The agent registry could not be fetched: offline')
    // A failure is retried a minute later, not at once.
    await registry.catalog()
    expect(net.calls).toHaveBeenCalledTimes(3)
    net.tick(60_000)
    net.responses.push(() => new Response('nope', { status: 503 }))
    expect((await registry.catalog()).error).toMatch(/HTTP 503/)

    // A restarted host with no network serves the copy it saved.
    const restarted = new AgentRegistry({ fetch: server().fetch, cachePath })
    const cached = await restarted.catalog()
    expect(cached.agents).toHaveLength(fixture.agents.length)
    expect(cached.error).toMatch(/offline/)
    expect(cached.fetchedAt).toBe(first.fetchedAt)
  })

  it('has no agents, and says why, before it has ever fetched', async () => {
    const registry = new AgentRegistry({ fetch: server().fetch })
    expect(await registry.catalog()).toEqual({ agents: [], fetchedAt: null, error: 'The agent registry could not be fetched: offline' })
  })

  it('shares one fetch between concurrent requests', async () => {
    const net = server()
    net.responses.push(ok(fixture))
    const registry = new AgentRegistry({ fetch: net.fetch, now: net.now })
    await Promise.all([registry.catalog(), registry.catalog(), registry.get('goose')])
    expect(net.calls).toHaveBeenCalledTimes(1)
  })
})
