import { once } from 'node:events'
import { mkdtemp, readFile, rm } from 'node:fs/promises'
import type { AddressInfo } from 'node:net'
import { tmpdir, type NetworkInterfaceInfo } from 'node:os'
import { join } from 'node:path'
import { afterEach, expect, it } from 'vitest'
import { ComputerRegistry, OWNER_COMPUTER, PhoneTokens } from './computers.js'
import { config } from './config.js'
import { hostId, lanAddresses, lanInterfaces, publicUrl, ReachService, Tailscale, tailscaleCommand, type Advertiser, type Run } from './reach.js'
import { createCabooseServer, type Controller } from './server.js'
import { SettingsStore, settingsLimits } from './settings.js'

const close: Array<() => Promise<void>> = []
afterEach(async () => { for (const f of close.splice(0).reverse()) await f() })

const v4 = (address: string, internal = false): NetworkInterfaceInfo => ({ address, netmask: '255.255.255.0', family: 'IPv4', mac: '00:00:00:00:00:00', internal, cidr: `${address}/24` })
const v6 = (address: string): NetworkInterfaceInfo => ({ address, netmask: 'ffff:ffff:ffff:ffff::', family: 'IPv6', mac: '00:00:00:00:00:00', internal: false, cidr: `${address}/64`, scopeid: 0 })
const machine = {
  lo: [v4('127.0.0.1', true)],
  eth0: [v4('192.168.1.20'), v6('fe80::1')],
  wlan0: [v4('10.0.0.7')],
  docker0: [v4('172.17.0.1')],
  'br-3f2a': [v4('172.18.0.1')],
  caboose0: [v4('10.200.0.1')],
  vethab12: [v4('169.254.3.3')],
  tailscale0: [v4('100.101.102.103')],
  utun4: [v4('100.64.0.2')],
  bridge100: [v4('192.168.64.1')],
  en0: [v4('169.254.10.1'), v4('192.168.68.85')],
}

it('lists only the addresses a phone on the network can use', () => {
  expect(lanInterfaces(machine)).toEqual([
    { name: 'eth0', address: '192.168.1.20' }, { name: 'wlan0', address: '10.0.0.7' }, { name: 'en0', address: '192.168.68.85' },
  ])
  expect(lanAddresses('0.0.0.0', 7310, machine)).toEqual(['http://192.168.1.20:7310', 'http://10.0.0.7:7310', 'http://192.168.68.85:7310'])
  expect(lanAddresses('127.0.0.1', 7310, machine)).toEqual([])
  expect(lanAddresses('localhost', 7310, machine)).toEqual([])
  expect(lanAddresses('192.168.1.20', 8080, machine)).toEqual(['http://192.168.1.20:8080'])
  expect(lanAddresses('fd00::5', 7310, machine)).toEqual(['http://[fd00::5]:7310'])
})

it('accepts a public URL only as a clean http(s) origin', () => {
  expect(publicUrl(undefined)).toBeNull()
  expect(publicUrl('https://caboose.example.com/')).toBe('https://caboose.example.com')
  expect(publicUrl('https://example.com/caboose')).toBe('https://example.com/caboose')
  expect(() => publicUrl('ftp://example.com')).toThrow(/http/)
  expect(() => publicUrl('https://user:pass@example.com')).toThrow(/credentials/)
  expect(() => publicUrl('not a url')).toThrow(/http/)
  expect(config({ CABOOSE_PUBLIC_URL: 'https://c.example.com/' }).publicUrl).toBe('https://c.example.com')
  expect(config({}).mdns).toBe(true)
  expect(config({ CABOOSE_MDNS: 'off' }).mdns).toBe(false)
  expect(() => config({ CABOOSE_MDNS: 'maybe' })).toThrow(/CABOOSE_MDNS/)
})

it('finds the Tailscale CLI on PATH or in the macOS app', () => {
  expect(tailscaleCommand(path => path === '/usr/sbin/tailscale', '/usr/bin:/usr/sbin')).toBe('/usr/sbin/tailscale')
  expect(tailscaleCommand(path => path === '/Applications/Tailscale.app/Contents/MacOS/Tailscale', '/usr/bin')).toBe('/Applications/Tailscale.app/Contents/MacOS/Tailscale')
  expect(tailscaleCommand(() => false, '/usr/bin')).toBeNull()
})

/** A tailscale CLI with a tailnet that has HTTPS on, recording what it was asked. */
function fakeTailscale(state: { backend?: string; certs?: boolean; serving?: boolean; failServe?: string } = {}) {
  const calls: string[][] = []
  const name = 'studio.tail1234.ts.net'
  let serving = state.serving ?? false
  const run: Run = async (_command, args) => {
    calls.push(args)
    if (args[0] === 'status') {
      return { code: 0, stderr: '', stdout: JSON.stringify({ BackendState: state.backend ?? 'Running', Self: { DNSName: `${name}.` }, CertDomains: state.certs === false ? null : [name] }) }
    }
    if (args[0] === 'serve' && args[1] === 'status') {
      return { code: 0, stderr: '', stdout: JSON.stringify(serving ? { TCP: { 443: { HTTPS: true } }, Web: { [`${name}:443`]: { Handlers: { '/': { Proxy: 'http://127.0.0.1:7310' } } } } } : {}) }
    }
    if (state.failServe) return { code: 1, stdout: '', stderr: `${state.failServe}\nmore` }
    serving = args.at(-1) !== 'off'
    return { code: 0, stdout: '', stderr: '' }
  }
  return { tailscale: new Tailscale(7310, '/usr/bin/tailscale', run), calls }
}

it('reports and switches Tailscale serve', async () => {
  const { tailscale, calls } = fakeTailscale()
  expect(await tailscale.status()).toEqual({ installed: true, loggedIn: true, name: 'studio.tail1234.ts.net', serving: false })
  expect(await tailscale.setServing(true)).toEqual({ installed: true, loggedIn: true, name: 'studio.tail1234.ts.net', serving: true, httpsUrl: 'https://studio.tail1234.ts.net' })
  expect(calls).toContainEqual(['serve', '--bg', '--https=443', 'http://127.0.0.1:7310'])
  // Asking again changes nothing.
  const before = calls.length
  await tailscale.setServing(true)
  expect(calls.slice(before).some(args => args.includes('--bg'))).toBe(false)
  expect((await tailscale.setServing(false)).serving).toBe(false)
  expect(calls).toContainEqual(['serve', '--https=443', 'off'])
})

it('explains why Tailscale cannot serve', async () => {
  await expect(new Tailscale(7310, null).setServing(true)).rejects.toThrow(/not installed.*tailscale.com\/download/)
  expect(await new Tailscale(7310, null).status()).toEqual({ installed: false, loggedIn: false, serving: false })
  const signedOut = fakeTailscale({ backend: 'NeedsLogin' }).tailscale
  expect(await signedOut.status()).toMatchObject({ installed: true, loggedIn: false, error: 'Tailscale is signed out on this machine' })
  await expect(signedOut.setServing(true)).rejects.toThrow(/signed out/)
  const noCerts = fakeTailscale({ certs: false }).tailscale
  expect((await noCerts.status()).error).toMatch(/HTTPS certificates are not enabled.*login.tailscale.com\/admin\/dns/)
  await expect(noCerts.setServing(true)).rejects.toThrow(/HTTPS certificates/)
  await expect(fakeTailscale({ failServe: 'serve config denied' }).tailscale.setServing(true)).rejects.toThrow('serve config denied')
  // A serve that proxies somewhere else is someone else's, and is never replaced.
  const other = fakeTailscale({ serving: true })
  const elsewhere = new Tailscale(9999, '/usr/bin/tailscale', other.tailscale['run'])
  expect(await elsewhere.status()).toMatchObject({ serving: false, error: expect.stringMatching(/already serves something else/) })
  await expect(elsewhere.setServing(true)).rejects.toThrow(/already serves something else/)
  expect(other.calls.some(args => args.includes('--bg'))).toBe(false)
})

it('preserves shared Serve routes and refuses unreadable configuration', async () => {
  const name = 'studio.tail1234.ts.net'
  const own = { Proxy: 'http://127.0.0.1:7310' }
  for (const handlers of [{ '/': own, '/other': { Proxy: 'http://127.0.0.1:9999' } }, { '/subpath': own }]) {
    const calls: string[][] = []
    const tailscale = new Tailscale(7310, 'tailscale', async (_, args) => {
      calls.push(args)
      return { code: 0, stderr: '', stdout: JSON.stringify(args[0] === 'status'
        ? { BackendState: 'Running', Self: { DNSName: name }, CertDomains: [name] }
        : { TCP: { 443: { HTTPS: true } }, Web: { [`${name}:443`]: { Handlers: handlers } } }) }
    })
    const status = await tailscale.status()
    expect(status.error).toMatch(/already serves something else/)
    await expect(tailscale.setServing(!status.serving)).rejects.toThrow(/already serves something else/)
    expect(calls.every(args => args[0] === 'status' || args[1] === 'status')).toBe(true)
  }
  for (const result of [{ code: 1, stdout: '', stderr: 'denied' }, { code: 0, stdout: 'invalid', stderr: '' }]) {
    const calls: string[][] = []
    const tailscale = new Tailscale(7310, 'tailscale', async (_, args) => {
      calls.push(args)
      return args[0] === 'status' ? { code: 0, stderr: '', stdout: JSON.stringify({ BackendState: 'Running', Self: { DNSName: name }, CertDomains: [name] }) } : result
    })
    await expect(tailscale.setServing(true)).rejects.toThrow(/Cannot read/)
    expect(calls.every(args => args[0] === 'status' || args[1] === 'status')).toBe(true)
  }
})

it('keeps one host id', async () => {
  const root = await mkdtemp(join(tmpdir(), 'caboose-reach-'))
  close.push(() => rm(root, { recursive: true, force: true }))
  const id = await hostId(join(root, 'state', 'host-id'))
  expect(id).toMatch(/^[0-9a-f]{16}$/)
  expect(await hostId(join(root, 'state', 'host-id'))).toBe(id)
  expect((await readFile(join(root, 'state', 'host-id'), 'utf8')).trim()).toBe(id)
})

function fakeAdvertiser() {
  const advertised: Array<Parameters<Advertiser['advertise']>[0]> = []
  let stopped = 0
  return { advertised, stopped: () => stopped, factory: async (): Promise<Advertiser> => ({ advertise: async service => { advertised.push(service) }, stop: async () => { stopped += 1 } }) }
}

it('advertises on the LAN interfaces and lists addresses best first', async () => {
  const mdns = fakeAdvertiser()
  const { tailscale } = fakeTailscale({ serving: true })
  const reach = new ReachService({ bind: '0.0.0.0', port: 7310, publicUrl: 'https://caboose.example.com', mdns: true, id: '0123456789abcdef', name: () => 'Studio', tailscale, advertiser: mdns.factory, interfaces: () => machine })
  await reach.start()
  expect(mdns.advertised).toEqual([{ name: 'Studio', hostname: 'caboose-01234567', port: 7310, interfaces: ['eth0', 'wlan0', 'en0'], txt: { v: '1', id: '0123456789abcdef', name: 'Studio', path: '/' } }])
  const status = await reach.status()
  expect(status.addresses).toEqual([
    { url: 'https://caboose.example.com', kind: 'public' },
    { url: 'https://studio.tail1234.ts.net', kind: 'tailscale' },
    { url: 'http://192.168.1.20:7310', kind: 'lan' }, { url: 'http://10.0.0.7:7310', kind: 'lan' }, { url: 'http://192.168.68.85:7310', kind: 'lan' },
  ])
  expect(status.mdns).toEqual({ enabled: true, name: 'Studio' })
  await reach.stop()
  expect(mdns.stopped()).toBe(1)
  expect((await reach.status()).mdns).toEqual({ enabled: false, name: null })
})

it('does not advertise a host the LAN cannot reach, or when told not to', async () => {
  for (const options of [{ bind: '127.0.0.1', mdns: true }, { bind: '0.0.0.0', mdns: false }]) {
    const mdns = fakeAdvertiser()
    const reach = new ReachService({ ...options, port: 7310, publicUrl: null, id: '0123456789abcdef', name: () => 'Caboose', tailscale: new Tailscale(7310, null), advertiser: mdns.factory, interfaces: () => machine })
    await reach.start()
    expect(mdns.advertised).toEqual([])
    expect((await reach.status()).mdns.enabled).toBe(false)
  }
})

it('serves reachability to the owner only', async () => {
  const root = await mkdtemp(join(tmpdir(), 'caboose-reach-'))
  close.push(() => rm(root, { recursive: true, force: true }))
  const computers = await ComputerRegistry.open(root)
  const phones = PhoneTokens.memory()
  const controller = { stats: () => ({}) } as unknown as Controller
  const settings = new SettingsStore({ name: 'Caboose', memoryMb: 2048, vcpus: 2, idleMs: 600_000, defaultAgent: null }, settingsLimits(), { load: async () => undefined, save: async () => {} })
  const { tailscale } = fakeTailscale()
  const reach = new ReachService({ bind: '0.0.0.0', port: 7310, publicUrl: null, mdns: false, id: '0123456789abcdef', name: () => 'Caboose', tailscale, interfaces: () => machine })
  const app = createCabooseServer({ token: 'owner', settings, controller, reach, fleet: { computers, phones, open: async () => { throw new Error('unused') }, defaults: { memoryMb: 2048, vcpus: 2, idleMs: 600_000 }, maxRunning: 4 } })
  app.server.listen(0, '127.0.0.1')
  await once(app.server, 'listening')
  close.push(() => new Promise(resolve => app.server.close(() => resolve())))
  const base = `http://127.0.0.1:${(app.server.address() as AddressInfo).port}`
  const call = (path: string, token: string, init: { method?: string; body?: unknown } = {}) => fetch(`${base}${path}`, {
    method: init.method ?? 'GET', headers: { authorization: `Bearer ${token}`, 'content-type': 'application/json' },
    ...(init.body !== undefined ? { body: JSON.stringify(init.body) } : {}),
  })

  const reply = await call('/v1/host/reach', 'owner')
  expect(reply.status).toBe(200)
  expect(await reply.json()).toMatchObject({ addresses: [{ kind: 'lan', url: 'http://192.168.1.20:7310' }, {}, {}], mdns: { enabled: false }, tailscale: { installed: true, serving: false } })
  const { token: phone } = await phones.mint(OWNER_COMPUTER, 'iPhone')
  expect((await call('/v1/host/reach', phone)).status).toBe(403)
  expect((await call('/v1/host/reach/tailscale', phone, { method: 'PUT', body: { enabled: true } })).status).toBe(403)
  expect((await call('/v1/host/reach', 'wrong')).status).toBe(401)

  expect((await call('/v1/host/reach/tailscale', 'owner', { method: 'PUT', body: { enabled: 'yes' } })).status).toBe(400)
  expect((await call('/v1/host/reach/tailscale', 'owner', { method: 'PUT', body: { enabled: true, extra: 1 } })).status).toBe(400)
  const on = await call('/v1/host/reach/tailscale', 'owner', { method: 'PUT', body: { enabled: true } })
  expect(on.status).toBe(200)
  expect(await on.json()).toMatchObject({ addresses: [{ kind: 'tailscale', url: 'https://studio.tail1234.ts.net' }, {}, {}, {}], tailscale: { serving: true } })
})

it('answers 409 when Tailscale is unavailable', async () => {
  const root = await mkdtemp(join(tmpdir(), 'caboose-reach-'))
  close.push(() => rm(root, { recursive: true, force: true }))
  const settings = new SettingsStore({ name: 'Caboose', memoryMb: 2048, vcpus: 2, idleMs: 600_000, defaultAgent: null }, settingsLimits(), { load: async () => undefined, save: async () => {} })
  const reach = new ReachService({ bind: '127.0.0.1', port: 7310, publicUrl: null, mdns: false, id: '0123456789abcdef', name: () => 'Caboose', tailscale: new Tailscale(7310, null) })
  const app = createCabooseServer({ token: 'owner', settings, controller: { stats: () => ({}) } as unknown as Controller, reach })
  app.server.listen(0, '127.0.0.1')
  await once(app.server, 'listening')
  close.push(() => new Promise(resolve => app.server.close(() => resolve())))
  const reply = await fetch(`http://127.0.0.1:${(app.server.address() as AddressInfo).port}/v1/host/reach/tailscale`, {
    method: 'PUT', headers: { authorization: 'Bearer owner', 'content-type': 'application/json' }, body: JSON.stringify({ enabled: true }),
  })
  expect(reply.status).toBe(409)
  expect((await reply.json()).error).toMatch(/not installed/)
})
