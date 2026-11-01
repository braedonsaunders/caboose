import { describe, expect, it, vi } from 'vitest'
import { ROUTE_SCRIPT, TAILSCALE_IMAGE, TailnetNode, joinKey, parseTailscaleStatus, removeDevice, tailnetConfig, tailnetHostname, type TailnetConfig } from './tailnet.js'
import { companionRule, companionRulesIn } from './network.js'

describe('tailnet configuration', () => {
  it('signs in by default, and turns off', () => {
    expect(tailnetConfig({})).toEqual({ mode: 'login', image: TAILSCALE_IMAGE })
    expect(tailnetConfig({ CABOOSE_TAILNET: 'off', CABOOSE_TAILSCALE_AUTHKEY: 'tskey-auth-x' })).toEqual({ mode: 'off' })
    expect(() => tailnetConfig({ CABOOSE_TAILNET: 'yes' })).toThrow(/on" or "off/)
  })
  it('takes an auth key or an OAuth client, with tags', () => {
    expect(tailnetConfig({ CABOOSE_TAILSCALE_AUTHKEY: 'tskey-auth-abc-123' })).toEqual({ mode: 'authkey', image: TAILSCALE_IMAGE, authKey: 'tskey-auth-abc-123', tags: ['tag:caboose'] })
    expect(tailnetConfig({ CABOOSE_TAILSCALE_CLIENT_ID: 'k1', CABOOSE_TAILSCALE_CLIENT_SECRET: 'tskey-client-s', CABOOSE_TAILSCALE_TAGS: 'tag:caboose, tag:lab', CABOOSE_TAILSCALE_IMAGE: 'mirror/tailscale:1' }))
      .toEqual({ mode: 'oauth', image: 'mirror/tailscale:1', clientId: 'k1', clientSecret: 'tskey-client-s', tags: ['tag:caboose', 'tag:lab'] })
  })
  it('refuses mixed or malformed credentials', () => {
    expect(() => tailnetConfig({ CABOOSE_TAILSCALE_AUTHKEY: 'tskey-a', CABOOSE_TAILSCALE_CLIENT_ID: 'k' })).toThrow(/not both/)
    expect(() => tailnetConfig({ CABOOSE_TAILSCALE_CLIENT_ID: 'k' })).toThrow(/go together/)
    expect(() => tailnetConfig({ CABOOSE_TAILSCALE_AUTHKEY: 'secret value' })).toThrow(/auth key/)
    expect(() => tailnetConfig({ CABOOSE_TAILSCALE_TAGS: 'caboose' })).toThrow(/tags/)
  })
})

describe('tailnet device names', () => {
  it('turns a computer name into one DNS label', () => {
    expect(tailnetHostname('Dev Box')).toBe('dev-box')
    expect(tailnetHostname('  Café — Plex!  ')).toBe('cafe-plex')
    expect(tailnetHostname('🚂')).toBe('caboose')
    expect(tailnetHostname('a'.repeat(70))).toHaveLength(63)
    expect(tailnetHostname(`${'a'.repeat(62)}-b`)).toBe('a'.repeat(62))
  })
})

describe('tailscale status', () => {
  const running = {
    BackendState: 'Running', AuthURL: '',
    Self: { ID: 'nAbC123', HostName: 'dev-box', DNSName: 'dev-box.tailea5249.ts.net.', TailscaleIPs: ['fd7a:115c:a1e0::1234', '100.101.102.103', '8.8.8.8'] },
  }
  it('reads a running device', () => {
    expect(parseTailscaleStatus(running)).toEqual({ state: 'running', name: 'dev-box.tailea5249.ts.net', addresses: ['100.101.102.103', 'fd7a:115c:a1e0::1234'], nodeId: 'nAbC123' })
  })
  it('offers only a genuine sign-in link', () => {
    expect(parseTailscaleStatus({ BackendState: 'NeedsLogin', AuthURL: 'https://login.tailscale.com/a/1a2b3c' })).toEqual({ state: 'needs-login', loginUrl: 'https://login.tailscale.com/a/1a2b3c' })
    expect(parseTailscaleStatus({ BackendState: 'NeedsLogin', AuthURL: 'https://evil.example/a/1' })).toEqual({ state: 'starting' })
    expect(parseTailscaleStatus({ BackendState: 'NeedsMachineAuth' })).toEqual({ state: 'needs-approval' })
    expect(parseTailscaleStatus({ BackendState: 'Starting' })).toEqual({ state: 'starting' })
  })
  it('drops names and addresses that are not the tailnet’s', () => {
    expect(parseTailscaleStatus({ BackendState: 'Running', Self: { DNSName: 'bad name.', TailscaleIPs: [1, '10.0.0.1'], ID: '../x' } })).toEqual({ state: 'running' })
    expect(parseTailscaleStatus(null)).toMatchObject({ state: 'error' })
  })
})

function fakeFetch(responses: Array<{ status?: number; body: unknown }>) {
  const calls: Array<{ url: string; init: { method: string; headers: Record<string, string>; body?: string } }> = []
  const fetch = vi.fn(async (url: string, init: { method: string; headers: Record<string, string>; body?: string }) => {
    calls.push({ url, init })
    const next = responses.shift()!
    const status = next.status ?? 200
    return { ok: status < 300, status, json: async () => next.body, text: async () => JSON.stringify(next.body) }
  })
  return { fetch, calls }
}

describe('tailnet keys', () => {
  const oauth: TailnetConfig = { mode: 'oauth', image: TAILSCALE_IMAGE, clientId: 'k1', clientSecret: 'tskey-client-s', tags: ['tag:caboose'] }
  it('mints a single-use, pre-authorized, tagged key that expires in five minutes', async () => {
    const { fetch, calls } = fakeFetch([{ body: { access_token: 'tok' } }, { body: { key: 'tskey-auth-new' } }])
    expect(await joinKey(oauth, 'Caboose dev-box', fetch)).toBe('tskey-auth-new')
    expect(calls[0]!.url).toBe('https://api.tailscale.com/api/v2/oauth/token')
    expect(calls[0]!.init.body).toContain('grant_type=client_credentials')
    expect(calls[1]!.init.headers.authorization).toBe('Bearer tok')
    expect(JSON.parse(calls[1]!.init.body!)).toEqual({ capabilities: { devices: { create: { reusable: false, ephemeral: false, preauthorized: true, tags: ['tag:caboose'] } } }, expirySeconds: 300, description: 'Caboose dev-box' })
  })
  it('uses an auth key as given, and needs none to sign in', async () => {
    expect(await joinKey({ mode: 'authkey', image: TAILSCALE_IMAGE, authKey: 'tskey-auth-k', tags: ['tag:caboose'] }, 'x')).toBe('tskey-auth-k')
    expect(await joinKey({ mode: 'login', image: TAILSCALE_IMAGE }, 'x')).toBeUndefined()
  })
  it('reports a refused client', async () => {
    const { fetch } = fakeFetch([{ status: 401, body: {} }])
    await expect(joinKey(oauth, 'x', fetch)).rejects.toThrow(/refused the OAuth client \(401\)/)
  })
  it('removes a device only with an OAuth client, treating a missing one as removed', async () => {
    const { fetch, calls } = fakeFetch([{ body: { access_token: 'tok' } }, { status: 404, body: {} }])
    await removeDevice(oauth, 'nAbC', fetch)
    expect(calls[1]!.url).toBe('https://api.tailscale.com/api/v2/device/nAbC')
    expect(calls[1]!.init.method).toBe('DELETE')
    const none = fakeFetch([])
    await removeDevice({ mode: 'login', image: TAILSCALE_IMAGE }, 'nAbC', none.fetch)
    expect(none.fetch).not.toHaveBeenCalled()
  })
})

describe('the companion’s routing', () => {
  it('forwards the tailnet to the computer, lets it answer, and refuses everything it starts', () => {
    expect(ROUTE_SCRIPT).toContain('-A CABOOSE-IN -j DNAT --to-destination "$target"')
    // Caboose's own services (display, files, terminal) are never on the tailnet.
    for (const protocol of ['tcp', 'udp']) {
      expect(ROUTE_SCRIPT.indexOf(`-A CABOOSE-IN -p ${protocol} --dport 14600:14799 -j RETURN`)).toBeLessThan(ROUTE_SCRIPT.indexOf('-j DNAT'))
      expect(ROUTE_SCRIPT.indexOf(`-p ${protocol} --dport 14600:14799 -j DROP`)).toBeLessThan(ROUTE_SCRIPT.indexOf('-A CABOOSE-FWD -i tailscale0 -o "$dev" -d "$target" -j ACCEPT'))
    }
    expect(ROUTE_SCRIPT).toContain('-A CABOOSE-FWD -i "$dev" -o tailscale0 -s "$target" -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT')
    expect(ROUTE_SCRIPT.indexOf('-A CABOOSE-FWD -j DROP')).toBeGreaterThan(ROUTE_SCRIPT.indexOf('-A CABOOSE-FWD -i tailscale0'))
    expect(ROUTE_SCRIPT).toContain('-A CABOOSE-CIN -j DROP')
    expect(ROUTE_SCRIPT).toContain('ip6tables -P FORWARD DROP')
  })
  it('names the host fence’s one exception so it can be replaced', () => {
    const rule = companionRule('caboose-br3', '172.22.0.3', '172.22.0.2')
    const listing = `-P DOCKER-USER ACCEPT\n-A DOCKER-USER ${rule.join(' ')}\n-A DOCKER-USER -i caboose-br3 -j CABOOSE-CFWD\n-A DOCKER-USER ${companionRule('caboose-br4', '172.23.0.3', '172.23.0.2').join(' ')}\n`
    expect(companionRulesIn(listing, 'caboose-br3')).toEqual([rule])
  })
})

/** A Docker that keeps the companion's state, answering what TailnetNode asks. */
function fakeDocker(options: { backend?: () => unknown } = {}) {
  const calls: string[][] = []
  let companion: 'missing' | 'created' | 'running' = 'missing'
  let uplink = false
  let signedIn = false
  const docker = vi.fn(async (args: string[]) => {
    calls.push(args)
    const [command] = args
    if (command === 'network' && args[1] === 'inspect' && args[2] === 'caboose-uplink') { if (!uplink) throw new Error('no such network'); return '' }
    if (command === 'network' && args[1] === 'inspect') return '172.30.0.1 '
    if (command === 'network' && args[1] === 'create') { uplink = true; return 'id' }
    if (command === 'inspect' && args.at(-1) === 'caboose-owner-net' && args[2] === '{{.State.Status}}') { if (companion === 'missing') throw new Error('No such object'); return companion }
    if (command === 'inspect') return args.at(-1) === 'caboose-owner' ? '172.19.0.2\n' : '172.19.0.3\n'
    if (command === 'create') { companion = 'created'; return 'id' }
    if (command === 'start') { companion = 'running'; return '' }
    if (command === 'exec' && args.includes('up')) signedIn = true
    if (command === 'exec' && args.includes('status')) return JSON.stringify(options.backend?.() ?? (signedIn ? { BackendState: 'NeedsLogin', AuthURL: 'https://login.tailscale.com/a/abc' } : { BackendState: 'NeedsLogin' }))
    return ''
  })
  return { docker, calls }
}

describe('a computer’s companion', () => {
  const base = { name: 'caboose-owner-net', computer: 'caboose-owner', network: 'caboose', hostname: () => 'dev-box' }
  it('creates the companion with only network capabilities, routes it, and leaves a sign-in link', async () => {
    const { docker, calls } = fakeDocker()
    const allow = vi.fn(async () => {})
    const node = new TailnetNode({ ...base, config: { mode: 'login', image: TAILSCALE_IMAGE }, docker, allow })
    expect(await node.ensure()).toEqual({ state: 'needs-login', loginUrl: 'https://login.tailscale.com/a/abc' })
    const create = calls.find(args => args[0] === 'create')!
    expect(create.slice(create.indexOf('--cap-drop'), create.indexOf('--cap-drop') + 7)).toEqual(['--cap-drop', 'ALL', '--cap-add', 'NET_ADMIN', '--cap-add', 'NET_RAW', '--device'])
    expect(create).toContain('CABOOSE_UPLINK_GATEWAY=172.30.0.1')
    expect(create).toContain('caboose-owner-net:/var/lib/tailscale')
    expect(calls).toContainEqual(['network', 'connect', 'caboose', 'caboose-owner-net'])
    expect(allow).toHaveBeenCalledWith('172.19.0.3', '172.19.0.2')
    expect(calls.find(args => args[0] === 'exec' && args.includes(ROUTE_SCRIPT))?.at(-1)).toBe('172.19.0.2')
    const up = calls.find(args => args.includes('up'))!
    expect(up).toEqual(expect.arrayContaining(['--hostname=dev-box', '--netfilter-mode=off', '--accept-dns=false']))
    expect(up.some(arg => arg.startsWith('--advertise-tags') || arg.startsWith('--auth-key'))).toBe(false)
  })
  it('keeps a pending sign-in link rather than asking for another', async () => {
    const { docker, calls } = fakeDocker({ backend: () => ({ BackendState: 'NeedsLogin', AuthURL: 'https://login.tailscale.com/a/kept' }) })
    const node = new TailnetNode({ ...base, config: { mode: 'login', image: TAILSCALE_IMAGE }, docker, allow: async () => {} })
    expect(await node.ensure()).toEqual({ state: 'needs-login', loginUrl: 'https://login.tailscale.com/a/kept' })
    expect(calls.some(args => args.includes('up'))).toBe(false)
  })
  it('joins with a key through standard input, never an argument', async () => {
    let joined = false
    const { docker, calls } = fakeDocker({ backend: () => joined
      ? { BackendState: 'Running', Self: { ID: 'n1', DNSName: 'dev-box.tailea5249.ts.net.', TailscaleIPs: ['100.64.1.2'] } }
      : { BackendState: 'NeedsLogin' } })
    const dockerInput = vi.fn(async (_args: string[], _input: string) => { joined = true; return '' })
    const node = new TailnetNode({ ...base, config: { mode: 'authkey', image: TAILSCALE_IMAGE, authKey: 'tskey-auth-secret', tags: ['tag:caboose'] }, docker, dockerInput, allow: async () => {} })
    expect(await node.ensure()).toEqual({ state: 'running', name: 'dev-box.tailea5249.ts.net', addresses: ['100.64.1.2'] })
    expect(dockerInput.mock.calls[0]![1]).toBe('tskey-auth-secret')
    expect(dockerInput.mock.calls[0]![0]).toEqual(expect.arrayContaining(['--auth-key=file:/dev/stdin', '--advertise-tags=tag:caboose']))
    expect(calls.flat().join(' ')).not.toContain('tskey-auth-secret')
  })
  it('reports a failure instead of throwing, so a wake never fails for it', async () => {
    const docker = vi.fn(async () => { throw new Error('Cannot connect to the Docker daemon') })
    const node = new TailnetNode({ ...base, config: { mode: 'login', image: TAILSCALE_IMAGE }, docker, allow: async () => {} })
    expect(await node.ensure()).toEqual({ state: 'error', error: 'Cannot connect to the Docker daemon' })
  })
  it('leaves the tailnet and removes the companion and its keys', async () => {
    const { docker, calls } = fakeDocker()
    const node = new TailnetNode({ ...base, config: { mode: 'login', image: TAILSCALE_IMAGE }, docker, allow: async () => {} })
    await node.destroy()
    expect(calls.some(args => args.includes('logout'))).toBe(true)
    expect(calls).toContainEqual(['rm', '-f', 'caboose-owner-net'])
    expect(calls).toContainEqual(['volume', 'rm', '-f', 'caboose-owner-net'])
    expect(node.status).toEqual({ state: 'off' })
  })
})
