import { execFile } from 'node:child_process'
import type { Docker } from './container-driver.js'
import { CABOOSE_PORTS, type NetworkServer } from './network-activity.js'
import type { LanStatus } from './lan.js'

/**
 * Each container computer as its own device on the owner's tailnet (docs/network.md). A
 * companion container the host owns runs tailscaled with a kernel TUN in a network namespace
 * of its own, on two networks: the computer's own bridge, and `caboose-uplink` for the
 * WireGuard paths. Everything that reaches its tailnet address is sent on to the computer
 * (DNAT, then masquerade), and nothing the computer sends can start a connection into the
 * tailnet or through the companion. The computer itself gets no capability, device or
 * credential: the node's keys live in the companion's own volume.
 */

/** `CABOOSE_TAILNET` and how a new node joins: the owner's sign-in link, an auth key, or an OAuth client. */
export type TailnetConfig =
  | { mode: 'off' }
  | { mode: 'login'; image: string }
  | { mode: 'authkey'; image: string; authKey: string; tags: string[] }
  | { mode: 'oauth'; image: string; clientId: string; clientSecret: string; tags: string[] }

/** The companion image; a release pins it. */
export const TAILSCALE_IMAGE = 'tailscale/tailscale:v1.104.4'
export const UPLINK_NETWORK = 'caboose-uplink'
export const UPLINK_BRIDGE = 'caboose-up0'
const TAG = /^tag:[a-z0-9][a-z0-9-]{0,62}$/i

export function tailnetConfig(env: NodeJS.ProcessEnv): TailnetConfig {
  const enabled = env.CABOOSE_TAILNET ?? 'on'
  if (enabled !== 'on' && enabled !== 'off') throw new Error('CABOOSE_TAILNET must be "on" or "off"')
  if (enabled === 'off') return { mode: 'off' }
  const image = env.CABOOSE_TAILSCALE_IMAGE || TAILSCALE_IMAGE
  const tags = (env.CABOOSE_TAILSCALE_TAGS ?? 'tag:caboose').split(',').map(tag => tag.trim()).filter(Boolean)
  if (!tags.every(tag => TAG.test(tag))) throw new Error('CABOOSE_TAILSCALE_TAGS must be tags such as tag:caboose, separated by commas')
  const authKey = env.CABOOSE_TAILSCALE_AUTHKEY?.trim(), clientId = env.CABOOSE_TAILSCALE_CLIENT_ID?.trim(), clientSecret = env.CABOOSE_TAILSCALE_CLIENT_SECRET?.trim()
  if (authKey && (clientId || clientSecret)) throw new Error('Set CABOOSE_TAILSCALE_AUTHKEY or an OAuth client, not both')
  if (!!clientId !== !!clientSecret) throw new Error('CABOOSE_TAILSCALE_CLIENT_ID and CABOOSE_TAILSCALE_CLIENT_SECRET go together')
  if (authKey) {
    if (!/^tskey-[A-Za-z0-9-]+$/.test(authKey)) throw new Error('CABOOSE_TAILSCALE_AUTHKEY must be a Tailscale auth key (tskey-…)')
    return { mode: 'authkey', image, authKey, tags }
  }
  if (clientId && clientSecret) {
    if (!tags.length) throw new Error('An OAuth client needs CABOOSE_TAILSCALE_TAGS')
    return { mode: 'oauth', image, clientId, clientSecret, tags }
  }
  return { mode: 'login', image }
}

/** A DNS label for the device: the computer's name, lower-case, letters, digits and hyphens. */
export function tailnetHostname(name: string): string {
  const label = name.normalize('NFKD').replace(/[̀-ͯ]/g, '').toLowerCase()
    .replace(/[^a-z0-9]+/g, '-').replace(/^-+|-+$/g, '').slice(0, 63).replace(/-+$/, '')
  return label || 'caboose'
}

export type TailnetState = 'off' | 'starting' | 'needs-login' | 'needs-approval' | 'running' | 'error'

/** What the app and the console show about a computer's tailnet device. */
export interface TailnetStatus {
  state: TailnetState
  /** The MagicDNS name, `dev-box.tailnet.ts.net`. */
  name?: string
  /** Its tailnet addresses, IPv4 first. Only IPv4 reaches the computer. */
  addresses?: string[]
  /** While it needs sign-in: the link that adds it to the tailnet of whoever opens it. */
  loginUrl?: string
  error?: string
}

/** Where other machines reach a computer (docs/network.md). */
export interface ComputerNetwork {
  tailnet?: TailnetStatus
  /** Its own address on the home network (lan.ts). */
  lan?: LanStatus
  /** The servers another machine can reach on it, while it has an address of its own. */
  servers?: NetworkServer[]
}

const IPV4 = /^100\.(?:6[4-9]|[7-9]\d|1[01]\d|12[0-7])\.\d{1,3}\.\d{1,3}$/
const IPV6 = /^fd7a:115c:a1e0:[0-9a-f:]+$/i

/** `tailscale status --json`, field by field: it carries names chosen by whoever runs the tailnet. */
export function parseTailscaleStatus(value: unknown): TailnetStatus & { nodeId?: string } {
  if (!value || typeof value !== 'object') return { state: 'error', error: 'Tailscale returned no status' }
  const status = value as Record<string, unknown>
  const backend = typeof status.BackendState === 'string' ? status.BackendState : ''
  const self = status.Self && typeof status.Self === 'object' ? status.Self as Record<string, unknown> : {}
  const url = typeof status.AuthURL === 'string' && /^https:\/\/login\.tailscale\.com\/a\/[A-Za-z0-9]+$/.test(status.AuthURL) ? status.AuthURL : undefined
  if (backend === 'NeedsLogin') return url ? { state: 'needs-login', loginUrl: url } : { state: 'starting' }
  if (backend === 'NeedsMachineAuth') return { state: 'needs-approval' }
  if (backend !== 'Running') return { state: 'starting' }
  const dns = typeof self.DNSName === 'string' ? self.DNSName.replace(/\.$/, '').toLowerCase() : ''
  const addresses = Array.isArray(self.TailscaleIPs) ? self.TailscaleIPs.filter((ip): ip is string => typeof ip === 'string' && (IPV4.test(ip) || IPV6.test(ip))) : []
  addresses.sort((a, b) => Number(IPV6.test(a)) - Number(IPV6.test(b)))
  const nodeId = typeof self.ID === 'string' && /^[A-Za-z0-9]{1,64}$/.test(self.ID) ? self.ID : undefined
  return {
    state: 'running',
    ...(/^[a-z0-9]([a-z0-9-]{0,62})(\.[a-z0-9]([a-z0-9-]{0,62}))+$/.test(dns) && dns.length <= 253 ? { name: dns } : {}),
    ...(addresses.length ? { addresses } : {}),
    ...(nodeId ? { nodeId } : {}),
  }
}

type Fetch = (url: string, init: { method: string; headers: Record<string, string>; body?: string; signal?: AbortSignal }) => Promise<{ ok: boolean; status: number; json(): Promise<unknown>; text(): Promise<string> }>
const API = 'https://api.tailscale.com/api/v2'

async function oauthToken(config: Extract<TailnetConfig, { mode: 'oauth' }>, fetch: Fetch): Promise<string> {
  const response = await fetch(`${API}/oauth/token`, {
    method: 'POST', headers: { 'content-type': 'application/x-www-form-urlencoded' },
    body: new URLSearchParams({ client_id: config.clientId, client_secret: config.clientSecret, grant_type: 'client_credentials' }).toString(),
    signal: AbortSignal.timeout(15_000),
  })
  if (!response.ok) throw new Error(`Tailscale refused the OAuth client (${response.status})`)
  const body = await response.json() as { access_token?: unknown }
  if (typeof body.access_token !== 'string' || !body.access_token) throw new Error('Tailscale returned no access token')
  return body.access_token
}

/**
 * The key a new node joins with. An OAuth client mints a single-use, pre-authorized key for
 * the tags that expires in five minutes; an auth key is used as it is; sign-in needs none.
 */
export async function joinKey(config: TailnetConfig, description: string, fetch: Fetch = globalThis.fetch as unknown as Fetch): Promise<string | undefined> {
  if (config.mode === 'authkey') return config.authKey
  if (config.mode !== 'oauth') return undefined
  const token = await oauthToken(config, fetch)
  const response = await fetch(`${API}/tailnet/-/keys`, {
    method: 'POST', headers: { authorization: `Bearer ${token}`, 'content-type': 'application/json' },
    body: JSON.stringify({ capabilities: { devices: { create: { reusable: false, ephemeral: false, preauthorized: true, tags: config.tags } } }, expirySeconds: 300, description: description.slice(0, 50) }),
    signal: AbortSignal.timeout(15_000),
  })
  if (!response.ok) throw new Error(`Tailscale would not create an auth key (${response.status}): ${(await response.text()).slice(0, 200)}`)
  const body = await response.json() as { key?: unknown }
  if (typeof body.key !== 'string' || !body.key.startsWith('tskey-')) throw new Error('Tailscale returned no auth key')
  return body.key
}

/** Removes a deleted computer's device from the tailnet; only an OAuth client can. */
export async function removeDevice(config: TailnetConfig, nodeId: string, fetch: Fetch = globalThis.fetch as unknown as Fetch): Promise<void> {
  if (config.mode !== 'oauth') return
  const token = await oauthToken(config, fetch)
  const response = await fetch(`${API}/device/${encodeURIComponent(nodeId)}`, { method: 'DELETE', headers: { authorization: `Bearer ${token}` }, signal: AbortSignal.timeout(15_000) })
  if (!response.ok && response.status !== 404) throw new Error(`Tailscale would not remove the device (${response.status})`)
}

/**
 * The companion's entry point (BusyBox sh in the Tailscale image). It sends its own traffic
 * out through the uplink, then runs tailscaled with the kernel's TUN and its own netfilter
 * rules turned off; ROUTE_SCRIPT installs Caboose's.
 */
export const COMPANION_SCRIPT = `set -eu
if [ -n "\${CABOOSE_UPLINK_GATEWAY:-}" ]; then ip route replace default via "$CABOOSE_UPLINK_GATEWAY"; fi
mkdir -p /var/run/tailscale /var/lib/tailscale
exec tailscaled --state=/var/lib/tailscale/tailscaled.state --socket=/var/run/tailscale/tailscaled.sock --tun=tailscale0 --port=41641`

/**
 * Sends everything that arrives on tailscale0 to the computer ($1), as the companion, except
 * Caboose's own services (14600–14799), which only the host may reach. The
 * computer may answer but may not start anything: not to the tailnet, the companion, or past
 * it to the uplink. IPv6 is refused at once, so clients fall back to IPv4 without waiting.
 * Idempotent: every run replaces Caboose's chains.
 */
const CABOOSE_RANGE = `${CABOOSE_PORTS.min}:${CABOOSE_PORTS.max}`
export const ROUTE_SCRIPT = `set -eu
target=$1
dev=$(ip -4 route get "$target" | sed -n 's/.* dev \\([^ ]*\\).*/\\1/p' | head -n 1)
[ -n "$dev" ] || { echo "No route to the computer at $target" >&2; exit 1; }
chain() { iptables -t "$1" -N "$2" 2>/dev/null || iptables -t "$1" -F "$2"; }
hook() { t=$1; shift; iptables -t "$t" -C "$@" 2>/dev/null || iptables -t "$t" -I "$@"; }
chain nat CABOOSE-IN
iptables -t nat -A CABOOSE-IN -p tcp --dport ${CABOOSE_RANGE} -j RETURN
iptables -t nat -A CABOOSE-IN -p udp --dport ${CABOOSE_RANGE} -j RETURN
iptables -t nat -A CABOOSE-IN -j DNAT --to-destination "$target"
hook nat PREROUTING -i tailscale0 -j CABOOSE-IN
chain nat CABOOSE-OUT
iptables -t nat -A CABOOSE-OUT -o "$dev" -d "$target" -j MASQUERADE
hook nat POSTROUTING -j CABOOSE-OUT
chain filter CABOOSE-FWD
iptables -A CABOOSE-FWD -i tailscale0 -o "$dev" -d "$target" -p tcp --dport ${CABOOSE_RANGE} -j DROP
iptables -A CABOOSE-FWD -i tailscale0 -o "$dev" -d "$target" -p udp --dport ${CABOOSE_RANGE} -j DROP
iptables -A CABOOSE-FWD -i tailscale0 -o "$dev" -d "$target" -j ACCEPT
iptables -A CABOOSE-FWD -i "$dev" -o tailscale0 -s "$target" -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
iptables -A CABOOSE-FWD -j DROP
hook filter FORWARD -j CABOOSE-FWD
chain filter CABOOSE-CIN
iptables -A CABOOSE-CIN -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
iptables -A CABOOSE-CIN -j DROP
for old in $(iptables -S INPUT | sed -n 's/^-A INPUT -i \\([^ ]*\\) -j CABOOSE-CIN$/\\1/p'); do [ "$old" = "$dev" ] || iptables -D INPUT -i "$old" -j CABOOSE-CIN; done
hook filter INPUT -i "$dev" -j CABOOSE-CIN
ip6tables -N CABOOSE-IN6 2>/dev/null || ip6tables -F CABOOSE-IN6
ip6tables -A CABOOSE-IN6 -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
ip6tables -A CABOOSE-IN6 -p tcp -j REJECT --reject-with tcp-reset
ip6tables -A CABOOSE-IN6 -p ipv6-icmp -j ACCEPT
ip6tables -A CABOOSE-IN6 -j REJECT
ip6tables -C INPUT -i tailscale0 -j CABOOSE-IN6 2>/dev/null || ip6tables -I INPUT -i tailscale0 -j CABOOSE-IN6
ip6tables -P FORWARD DROP`

/** Runs docker with the given standard input, so a key never appears in an argument list. */
export type DockerInput = (args: string[], input: string, timeoutMs?: number) => Promise<string>

export function dockerInputCli(binary = 'docker'): DockerInput {
  return (args, input, timeoutMs = 60_000) => new Promise((resolve, reject) => {
    const child = execFile(binary, args, { timeout: timeoutMs, maxBuffer: 16 * 1024 * 1024 }, (error, stdout, stderr) => {
      if (error) reject(new Error(`docker ${args[0]} failed: ${(stderr || error.message).trim()}`))
      else resolve(stdout)
    })
    child.stdin?.end(input)
  })
}

export interface TailnetNodeOptions {
  config: Exclude<TailnetConfig, { mode: 'off' }>
  docker: Docker
  dockerInput?: DockerInput
  /** The companion container's name and its state volume's. */
  name: string
  /** The computer's container and its network. */
  computer: string
  network: string
  /** The device name the computer's name gives. */
  hostname: () => string
  /** Lets the companion reach the computer through the host's fence (network.ts). */
  allow: (companion: string, computer: string) => Promise<void>
  fetch?: Fetch
}

const TAILSCALE = ['tailscale', '--socket=/var/run/tailscale/tailscaled.sock']

/** One computer's companion: created and brought up at each wake, kept running while parked. */
export class TailnetNode {
  private current: TailnetStatus & { nodeId?: string } = { state: 'starting' }
  private hostname = ''
  constructor(private readonly options: TailnetNodeOptions) {}

  get status(): TailnetStatus {
    const { nodeId: _, ...status } = this.current
    return status
  }

  private async address(container: string, network: string): Promise<string> {
    const address = (await this.options.docker(['inspect', '-f', `{{with index .NetworkSettings.Networks "${network}"}}{{.IPAddress}}{{end}}`, container], 15_000)).trim()
    if (!/^(?:\d{1,3}\.){3}\d{1,3}$/.test(address)) throw new Error(`${container} has no address on ${network}`)
    return address
  }

  private async state(): Promise<'missing' | 'running' | 'stopped'> {
    try {
      const status = (await this.options.docker(['inspect', '-f', '{{.State.Status}}', this.options.name], 15_000)).trim()
      return status === 'running' ? 'running' : 'stopped'
    } catch { return 'missing' }
  }

  private async uplink(): Promise<string> {
    const { docker } = this.options
    try { await docker(['network', 'inspect', UPLINK_NETWORK], 15_000) }
    catch { await docker(['network', 'create', '--driver', 'bridge', '-o', `com.docker.network.bridge.name=${UPLINK_BRIDGE}`, UPLINK_NETWORK], 30_000) }
    const gateway = (await docker(['network', 'inspect', '-f', '{{range .IPAM.Config}}{{.Gateway}} {{end}}', UPLINK_NETWORK], 15_000)).trim().split(/\s+/).find(value => /^(?:\d{1,3}\.){3}\d{1,3}$/.test(value))
    if (!gateway) throw new Error(`${UPLINK_NETWORK} has no IPv4 gateway`)
    return gateway
  }

  private async create(): Promise<void> {
    const { docker, config, name, network } = this.options
    const gateway = await this.uplink()
    await docker(['create', '--name', name, '--hostname', this.options.hostname(), '--restart', 'unless-stopped',
      '--label', 'caboose.companion=tailnet', '--label', `caboose.computer=${this.options.computer}`,
      '--network', UPLINK_NETWORK, '--cap-drop', 'ALL', '--cap-add', 'NET_ADMIN', '--cap-add', 'NET_RAW', '--device', '/dev/net/tun',
      '--security-opt', 'no-new-privileges', '--memory', '256m', '--pids-limit', '200',
      '--sysctl', 'net.ipv4.ip_forward=1', '--sysctl', 'net.ipv6.conf.all.forwarding=1',
      '-e', `CABOOSE_UPLINK_GATEWAY=${gateway}`, '-v', `${name}:/var/lib/tailscale`,
      '--entrypoint', '/bin/sh', config.image, '-c', COMPANION_SCRIPT], 300_000)
    await docker(['network', 'connect', network, name], 30_000)
  }

  private async tailscale(args: string[], timeoutMs = 30_000): Promise<string> {
    return this.options.docker(['exec', this.options.name, ...TAILSCALE, ...args], timeoutMs)
  }

  private async read(): Promise<TailnetStatus & { nodeId?: string }> {
    let output: string
    try { output = await this.tailscale(['status', '--json', '--peers=false'], 15_000) }
    catch { return { state: 'starting' } }
    try { return parseTailscaleStatus(JSON.parse(output)) } catch { return { state: 'error', error: 'Tailscale returned an unreadable status' } }
  }

  /** Brings the companion up, routes it to the computer and joins the tailnet if it has not. */
  async ensure(): Promise<TailnetStatus> {
    try {
      const { docker, name, computer, network } = this.options
      const state = await this.state()
      if (state === 'missing') await this.create()
      if (state !== 'running') await docker(['start', name], 60_000)
      const target = await this.address(computer, network)
      await this.options.allow(await this.address(name, network), target)
      await docker(['exec', name, '/bin/sh', '-c', ROUTE_SCRIPT, 'sh', target], 30_000)
      let status: TailnetStatus & { nodeId?: string } = { state: 'starting' }
      for (let attempt = 0; attempt < 20; attempt++) {
        try { await this.tailscale(['version'], 5_000); status = await this.read(); break } catch { await new Promise(resolve => setTimeout(resolve, 250)) }
      }
      if (status.state === 'starting' || status.state === 'needs-login') await this.join()
      else if (status.state === 'running' && this.hostname !== this.options.hostname()) await this.rename()
      this.current = await this.read()
    } catch (error) {
      this.current = { state: 'error', error: error instanceof Error ? error.message : String(error) }
    }
    return this.status
  }

  /** `tailscale up` with Caboose's settings; with no key it leaves a sign-in link in the status. */
  private async join(): Promise<void> {
    const { config } = this.options
    const hostname = this.options.hostname()
    const key = await joinKey(config, `Caboose ${hostname}`, this.options.fetch)
    const args = ['up', '--reset', `--hostname=${hostname}`, '--netfilter-mode=off', '--accept-dns=false', '--accept-routes=false',
      ...(config.mode === 'login' ? [] : [`--advertise-tags=${config.tags.join(',')}`])]
    if (key) {
      if (!this.options.dockerInput) throw new Error('Joining with a key needs docker with standard input')
      await this.options.dockerInput(['exec', '-i', this.options.name, ...TAILSCALE, ...args, '--auth-key=file:/dev/stdin', '--timeout=60s'], key, 90_000)
    } else {
      // Sign-in waits for the owner; the backend keeps the link and finishes on its own.
      await this.tailscale([...args, '--timeout=5s'], 20_000).catch(() => {})
    }
    this.hostname = hostname
  }

  /** Follows a rename of the computer. */
  async rename(): Promise<void> {
    const hostname = this.options.hostname()
    await this.tailscale(['set', `--hostname=${hostname}`])
    this.hostname = hostname
  }

  /** Reads the device's state again, as when the owner may have just signed in. */
  async refresh(): Promise<TailnetStatus> {
    if (await this.state() !== 'running') this.current = { state: 'starting' }
    else this.current = await this.read()
    return this.status
  }

  /** Leaves the tailnet and deletes the companion and its keys, when the computer is deleted. */
  async destroy(): Promise<void> {
    const { docker, name, config } = this.options
    const nodeId = (await this.read().catch(() => ({} as { nodeId?: string }))).nodeId
    if (nodeId && config.mode === 'oauth') await removeDevice(config, nodeId, this.options.fetch).catch(error => console.error('Could not remove the tailnet device:', error instanceof Error ? error.message : error))
    else await this.tailscale(['logout'], 30_000).catch(() => {})
    await docker(['rm', '-f', name], 60_000).catch(() => {})
    await docker(['volume', 'rm', '-f', name], 60_000).catch(() => {})
    this.current = { state: 'off' }
  }
}
