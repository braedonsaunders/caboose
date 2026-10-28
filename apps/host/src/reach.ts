import { execFile } from 'node:child_process'
import { randomBytes } from 'node:crypto'
import { existsSync } from 'node:fs'
import { mkdir, readFile, writeFile } from 'node:fs/promises'
import { hostname, networkInterfaces, type NetworkInterfaceInfo } from 'node:os'
import { dirname } from 'node:path'

/**
 * How a phone finds and reaches this host (docs/architecture.md, "Reachability"): its LAN
 * addresses, an mDNS advertisement on the LAN, an operator's public URL, and Tailscale's
 * HTTPS `serve`, switched on and off from the console.
 */
export interface ReachAddress { url: string; kind: 'public' | 'tailscale' | 'lan' }

export interface TailscaleStatus {
  installed: boolean
  loggedIn: boolean
  /** The machine's MagicDNS name, without the trailing dot. */
  name?: string
  /** Whether `tailscale serve` sends HTTPS on 443 to this host. */
  serving: boolean
  httpsUrl?: string
  error?: string
}

export interface Reach {
  /** Best first: the public URL, then Tailscale, then the LAN. */
  addresses: ReachAddress[]
  mdns: { enabled: boolean; name: string | null }
  tailscale: TailscaleStatus
}

/** Tailscale cannot do what was asked: not installed, signed out, or HTTPS off for the tailnet. */
export class ReachUnavailableError extends Error {}

/** Interfaces a phone never reaches the host through: loopback, container and VM bridges, VPN tunnels and Apple's peer-to-peer links. */
const PRIVATE_INTERFACE = /^(lo\d*|docker|br-|caboose|veth|tap|virbr|vmnet|bridge|tailscale|utun|tun|wg|awdl|llw|anpi|ap\d|gif|stf|zt)/

/** The interfaces and IPv4 addresses a phone on the same network can use. */
export function lanInterfaces(interfaces: NodeJS.Dict<NetworkInterfaceInfo[]> = networkInterfaces()): Array<{ name: string; address: string }> {
  const found: Array<{ name: string; address: string }> = []
  for (const [name, entries] of Object.entries(interfaces)) {
    if (PRIVATE_INTERFACE.test(name)) continue
    for (const entry of entries ?? []) {
      if (entry.family !== 'IPv4' || entry.internal || entry.address.startsWith('169.254.')) continue
      found.push({ name, address: entry.address })
    }
  }
  return found
}

function isLoopback(bind: string): boolean {
  return bind === 'localhost' || bind === '::1' || bind.startsWith('127.')
}

function isWildcard(bind: string): boolean {
  return bind === '0.0.0.0' || bind === '::' || bind === ''
}

/** LAN URLs for a host listening on `bind`: none on loopback, the address itself when specific. */
export function lanAddresses(bind: string, port: number, interfaces?: NodeJS.Dict<NetworkInterfaceInfo[]>): string[] {
  if (isLoopback(bind)) return []
  if (!isWildcard(bind)) return [`http://${bind.includes(':') ? `[${bind}]` : bind}:${port}`]
  return [...new Set(lanInterfaces(interfaces).map(entry => `http://${entry.address}:${port}`))]
}

/** `CABOOSE_PUBLIC_URL`: an absolute http(s) origin with an optional path, without credentials. */
export function publicUrl(value: string | undefined): string | null {
  if (!value) return null
  let url: URL
  try { url = new URL(value) } catch { throw new Error('CABOOSE_PUBLIC_URL must be an http(s) URL') }
  if ((url.protocol !== 'https:' && url.protocol !== 'http:') || url.username || url.password || url.search || url.hash) {
    throw new Error('CABOOSE_PUBLIC_URL must be an http(s) URL without credentials, query or fragment')
  }
  return url.href.replace(/\/$/, '')
}

export type Run = (command: string, args: string[]) => Promise<{ code: number; stdout: string; stderr: string }>

const runCommand: Run = (command, args) => new Promise(resolve => {
  execFile(command, args, { timeout: 20_000, maxBuffer: 4 * 1024 * 1024 }, (error, stdout, stderr) => {
    const code = error ? (typeof (error as { code?: unknown }).code === 'number' ? (error as { code: number }).code : 127) : 0
    resolve({ code, stdout: String(stdout), stderr: String(stderr || (error && code === 127 ? error.message : '')) })
  })
})

/** Where the Tailscale CLI is: on PATH, or inside the macOS app. */
export function tailscaleCommand(exists: (path: string) => boolean = existsSync, path = process.env.PATH ?? ''): string | null {
  for (const dir of path.split(':').filter(Boolean)) if (exists(`${dir}/tailscale`)) return `${dir}/tailscale`
  for (const candidate of ['/Applications/Tailscale.app/Contents/MacOS/Tailscale', '/usr/bin/tailscale', '/usr/local/bin/tailscale', '/opt/homebrew/bin/tailscale']) {
    if (exists(candidate)) return candidate
  }
  return null
}

interface TailscaleJson { BackendState?: string; Self?: { DNSName?: string }; CertDomains?: string[] | null }
interface ServeJson { TCP?: Record<string, { HTTPS?: boolean }>; Web?: Record<string, { Handlers?: Record<string, { Proxy?: string }> }> }

const ADMIN_DNS = 'https://login.tailscale.com/admin/dns'

/** Tailscale's own CLI: `status --json`, `serve status --json`, and `serve` on or off for 443. */
export class Tailscale {
  constructor(private readonly port: number, private readonly command: string | null = tailscaleCommand(), private readonly run: Run = runCommand) {}

  async status(): Promise<TailscaleStatus> {
    if (!this.command) return { installed: false, loggedIn: false, serving: false }
    const status = await this.run(this.command, ['status', '--json'])
    let parsed: TailscaleJson
    try { parsed = JSON.parse(status.stdout) as TailscaleJson } catch {
      return { installed: true, loggedIn: false, serving: false, error: firstLine(status.stderr) || 'Tailscale is not running' }
    }
    if (parsed.BackendState !== 'Running') return { installed: true, loggedIn: false, serving: false, error: parsed.BackendState === 'NeedsLogin' ? 'Tailscale is signed out on this machine' : `Tailscale is ${parsed.BackendState ?? 'not running'}` }
    const name = parsed.Self?.DNSName?.replace(/\.$/, '')
    const certified = !!name && (parsed.CertDomains ?? []).includes(name)
    const { serving, taken, error: serveError } = await this.serving(name)
    const error = serveError ?? (!certified ? `HTTPS certificates are not enabled for this tailnet; turn on MagicDNS and HTTPS at ${ADMIN_DNS}`
      : taken ? 'Tailscale already serves something else on HTTPS port 443 of this machine; manage its routes in Tailscale'
      : undefined)
    return {
      installed: true, loggedIn: true, ...(name ? { name } : {}), serving,
      ...(serving && name ? { httpsUrl: `https://${name}` } : {}),
      ...(error ? { error } : {}),
    }
  }

  /** Whether 443 on this machine's name proxies to this host, or is taken by something else. */
  private async serving(name: string | undefined): Promise<{ serving: boolean; taken: boolean; error?: string }> {
    if (!this.command || !name) return { serving: false, taken: false }
    const result = await this.run(this.command, ['serve', 'status', '--json'])
    const unreadable = { serving: false, taken: false, error: 'Cannot read Tailscale Serve configuration; no routes were changed' }
    if (result.code !== 0) return unreadable
    let parsed: ServeJson
    try {
      parsed = JSON.parse(result.stdout) as ServeJson
      if (!parsed || typeof parsed !== 'object' || Array.isArray(parsed)) return unreadable
    } catch { return unreadable }
    const routes = Object.entries(parsed.Web ?? {}).filter(([address]) => address.endsWith(':443'))
      .flatMap(([address, config]) => Object.entries(config.Handlers ?? {}).map(([path, handler]) => ({ address, path, handler })))
    const ours = (route: typeof routes[number]) => route.address === `${name}:443` && route.path === '/'
      && route.handler.Proxy !== undefined && proxiesTo(route.handler.Proxy, this.port)
    const serving = parsed.TCP?.['443']?.HTTPS === true && routes.some(ours)
    // Turning off 443 removes all its handlers. Never do that when another route shares it.
    const taken = routes.some(route => !ours(route)) || (parsed.TCP?.['443'] !== undefined && !serving)
    return { serving, taken }
  }

  async setServing(enabled: boolean): Promise<TailscaleStatus> {
    const before = await this.status()
    if (!this.command || !before.installed) throw new ReachUnavailableError('Tailscale is not installed on this machine: https://tailscale.com/download')
    if (!before.loggedIn) throw new ReachUnavailableError(before.error ?? 'Tailscale is signed out on this machine')
    if (before.serving === enabled) return before
    if (before.error) throw new ReachUnavailableError(before.error)
    const args = enabled ? ['serve', '--bg', '--https=443', `http://127.0.0.1:${this.port}`] : ['serve', '--https=443', 'off']
    const result = await this.run(this.command, args)
    if (result.code !== 0) throw new ReachUnavailableError(firstLine(result.stderr) || firstLine(result.stdout) || `tailscale serve exited with ${result.code}`)
    return this.status()
  }
}

function proxiesTo(proxy: string, port: number): boolean {
  try {
    const url = new URL(proxy)
    return url.protocol === 'http:' && (url.hostname === '127.0.0.1' || url.hostname === 'localhost')
      && Number(url.port) === port && url.pathname === '/' && !url.search && !url.hash && !url.username && !url.password
  } catch {
    return proxy === String(port) || proxy === `127.0.0.1:${port}` || proxy === `localhost:${port}`
  }
}

function firstLine(text: string): string {
  return text.trim().split('\n')[0]?.trim() ?? ''
}

/** A random id that names this host on the LAN, kept in the state directory. */
export async function hostId(path: string): Promise<string> {
  try {
    const value = (await readFile(path, 'utf8')).trim()
    if (/^[0-9a-f]{16}$/.test(value)) return value
  } catch (error) {
    if ((error as NodeJS.ErrnoException).code !== 'ENOENT') throw error
  }
  const id = randomBytes(8).toString('hex')
  await mkdir(dirname(path), { recursive: true })
  await writeFile(path, `${id}\n`, { mode: 0o644 })
  return id
}

/** The pieces of an mDNS responder the host uses (`@homebridge/ciao`). */
export interface Advertiser {
  advertise(service: { name: string; hostname: string; port: number; txt: Record<string, string>; interfaces: string[] }): Promise<void>
  stop(): Promise<void>
}

export async function ciaoAdvertiser(): Promise<Advertiser> {
  const { default: ciao } = await import('@homebridge/ciao')
  const responder = ciao.getResponder()
  let service: ReturnType<typeof responder.createService> | undefined
  return {
    async advertise(options) {
      service = responder.createService({
        name: options.name, type: 'caboose', port: options.port, hostname: options.hostname, txt: options.txt,
        restrictedAddresses: options.interfaces, disabledIpv6: true,
      })
      await service.advertise()
    },
    async stop() {
      await service?.end()
      await responder.shutdown()
    },
  }
}

export interface ReachOptions {
  bind: string
  port: number
  publicUrl: string | null
  mdns: boolean
  /** The host's id, from the state directory. */
  id: string
  /** The name shown on phones: the owner computer's name. */
  name: () => string
  tailscale?: Tailscale
  advertiser?: () => Promise<Advertiser>
  interfaces?: () => NodeJS.Dict<NetworkInterfaceInfo[]>
}

export class ReachService {
  private readonly tailscale: Tailscale
  private advertiser: Advertiser | undefined
  private advertisedName: string | null = null

  constructor(private readonly options: ReachOptions) {
    this.tailscale = options.tailscale ?? new Tailscale(options.port)
  }

  /** Advertises `_caboose._tcp` when the host is reachable from the LAN and mDNS is on. */
  async start(): Promise<void> {
    if (!this.options.mdns || isLoopback(this.options.bind)) return
    const interfaces = [...new Set(lanInterfaces(this.options.interfaces?.()).map(entry => entry.name))]
    if (!interfaces.length) return
    const name = this.options.name().slice(0, 63) || 'Caboose'
    this.advertiser = await (this.options.advertiser ?? ciaoAdvertiser)()
    await this.advertiser.advertise({
      name, hostname: `caboose-${this.options.id.slice(0, 8)}`, port: this.options.port, interfaces,
      txt: { v: '1', id: this.options.id, name, path: '/' },
    })
    this.advertisedName = name
  }

  async stop(): Promise<void> {
    await this.advertiser?.stop()
    this.advertiser = undefined
    this.advertisedName = null
  }

  async status(): Promise<Reach> {
    const tailscale = await this.tailscale.status()
    return this.describe(tailscale)
  }

  async setTailscale(enabled: boolean): Promise<Reach> {
    return this.describe(await this.tailscale.setServing(enabled))
  }

  private describe(tailscale: TailscaleStatus): Reach {
    const addresses: ReachAddress[] = []
    if (this.options.publicUrl) addresses.push({ url: this.options.publicUrl, kind: 'public' })
    if (tailscale.httpsUrl) addresses.push({ url: tailscale.httpsUrl, kind: 'tailscale' })
    for (const url of lanAddresses(this.options.bind, this.options.port, this.options.interfaces?.())) addresses.push({ url, kind: 'lan' })
    return { addresses, mdns: { enabled: this.advertisedName !== null, name: this.advertisedName }, tailscale }
  }
}

/** The machine's own name, for a host that has not been named. */
export const machineName = () => hostname().replace(/\.local$/, '')
