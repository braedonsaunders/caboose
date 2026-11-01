import { createHash } from 'node:crypto'
import { readFileSync } from 'node:fs'
import type { Docker } from './container-driver.js'
import { CABOOSE_PORTS } from './network-activity.js'
import { TAILSCALE_IMAGE } from './tailnet.js'

/**
 * A container computer's own address on the home network (docs/network.md): a macvlan (or
 * ipvlan) interface on the host's Ethernet, moved into the computer's network namespace as
 * `lan0`, with a lease from the network's own DHCP server. A helper container the host owns
 * joins the computer's namespace with NET_ADMIN to run the DHCP client and install lan0's
 * fence; the computer itself gains no capability. Linux hosts only: WSL and macOS have no
 * Ethernet of their own to share.
 */
export type LanConfig =
  | { mode: 'off' }
  | { mode: 'macvlan' | 'ipvlan'; interface: string; image: string; allowOut: boolean }

const INTERFACE = /^[A-Za-z0-9_.-]{1,15}$/

function osRelease(): string {
  try { return readFileSync('/proc/sys/kernel/osrelease', 'utf8') } catch { return '' }
}

export function lanConfig(env: NodeJS.ProcessEnv, platform: string = process.platform, release: () => string = osRelease): LanConfig {
  const parent = env.CABOOSE_LAN_INTERFACE?.trim()
  if (!parent) return { mode: 'off' }
  if (!INTERFACE.test(parent)) throw new Error('CABOOSE_LAN_INTERFACE must be a network interface name')
  if (platform !== 'linux' || /microsoft/i.test(release())) throw new Error('CABOOSE_LAN_INTERFACE needs a Linux host with its own Ethernet; WSL and macOS cannot share theirs')
  const mode = env.CABOOSE_LAN_MODE ?? 'macvlan'
  if (mode !== 'macvlan' && mode !== 'ipvlan') throw new Error('CABOOSE_LAN_MODE must be "macvlan" or "ipvlan"')
  return { mode, interface: parent, image: env.CABOOSE_TAILSCALE_IMAGE || TAILSCALE_IMAGE, allowOut: env.CABOOSE_GUEST_LAN === 'allow' }
}

/** A stable, locally administered MAC for the computer, so its DHCP lease (and address) stays the same. */
export function lanMac(computer: string): string {
  const bytes = createHash('sha256').update(`caboose-lan:${computer}`).digest().subarray(0, 6)
  bytes[0] = (bytes[0]! & 0xfc) | 0x02
  return [...bytes].map(byte => byte.toString(16).padStart(2, '0')).join(':')
}

export interface LanStatus {
  state: 'starting' | 'running' | 'error'
  /** Its address from the network's DHCP server. */
  address?: string
  /** Its mDNS name, `dev-box.local`. */
  name?: string
  error?: string
}

const RANGE = `${CABOOSE_PORTS.min}:${CABOOSE_PORTS.max}`

/**
 * The helper's entry point, in the computer's network namespace. It names the interface lan0,
 * fences it, and runs BusyBox's DHCP client, which sets only lan0's address and its subnet:
 * the computer's default route and DNS stay on its own bridge. Caboose's ports are never
 * reachable on lan0. The computer may answer anything and join discovery (multicast, mDNS
 * and SSDP replies); it starts nothing else on the LAN unless CABOOSE_LAN_OUT is "allow".
 */
export const LAN_SCRIPT = `set -eu
if ip link show "$CABOOSE_LINK" >/dev/null 2>&1; then
  ip link show lan0 >/dev/null 2>&1 && ip link del lan0
  ip link set "$CABOOSE_LINK" name lan0
fi
ip link set lan0 up
for t in iptables ip6tables; do
  $t -N CABOOSE-LAN-IN 2>/dev/null || $t -F CABOOSE-LAN-IN
  $t -A CABOOSE-LAN-IN -p tcp --dport ${RANGE} -j DROP
  $t -A CABOOSE-LAN-IN -p udp --dport ${RANGE} -j DROP
  $t -C INPUT -i lan0 -j CABOOSE-LAN-IN 2>/dev/null || $t -I INPUT -i lan0 -j CABOOSE-LAN-IN
  $t -N CABOOSE-LAN-OUT 2>/dev/null || $t -F CABOOSE-LAN-OUT
  if [ "\${CABOOSE_LAN_OUT:-deny}" != allow ]; then
    $t -A CABOOSE-LAN-OUT -m conntrack --ctstate ESTABLISHED,RELATED -j RETURN
    $t -A CABOOSE-LAN-OUT -p udp --sport 5353 -j RETURN
    $t -A CABOOSE-LAN-OUT -p udp --sport 1900 -j RETURN
    $t -A CABOOSE-LAN-OUT -j REJECT
  fi
  $t -C OUTPUT -o lan0 -j CABOOSE-LAN-OUT 2>/dev/null || $t -I OUTPUT -o lan0 -j CABOOSE-LAN-OUT
done
if [ "\${CABOOSE_LAN_OUT:-deny}" != allow ]; then
  iptables -I CABOOSE-LAN-OUT 1 -d 224.0.0.0/4 -p udp -j RETURN
  iptables -I CABOOSE-LAN-OUT 1 -p igmp -j RETURN
  ip6tables -I CABOOSE-LAN-OUT 1 -d ff00::/8 -j RETURN
fi
cat > /tmp/caboose-dhcp <<'EOF'
#!/bin/sh
case "$1" in
  deconfig) ip -4 addr flush dev "$interface" ;;
  bound|renew)
    ip -4 -o addr show dev "$interface" | grep -q " $ip/" || ip -4 addr flush dev "$interface"
    ip -4 addr replace "$ip/\${mask:-24}" dev "$interface" ;;
esac
EOF
chmod 0755 /tmp/caboose-dhcp
exec udhcpc -f -i lan0 -x hostname:"$CABOOSE_HOSTNAME" -s /tmp/caboose-dhcp`

export interface LanAddressOptions {
  config: Exclude<LanConfig, { mode: 'off' }>
  docker: Docker
  /** Runs a command as root on the host (network.ts). */
  privileged: (command: string, args: string[]) => Promise<string>
  /** The computer's container and its slot, which names the host-side link. */
  computer: string
  slot: number
  hostname: () => string
}

const IPV4 = /\binet (\d{1,3}(?:\.\d{1,3}){3})\//

/** One computer's address on the home network, set up again after each wake. */
export class LanAddress {
  private current: LanStatus = { state: 'starting' }
  constructor(private readonly options: LanAddressOptions) {}

  get status(): LanStatus { return { ...this.current } }
  private get helper(): string { return `${this.options.computer}-lan` }
  private get link(): string { return `cbl${this.options.slot}` }

  private async address(): Promise<string | undefined> {
    try { return IPV4.exec(await this.options.docker(['exec', this.helper, 'ip', '-4', '-o', 'addr', 'show', 'dev', 'lan0'], 10_000))?.[1] }
    catch { return undefined }
  }

  async ensure(): Promise<LanStatus> {
    const { docker, privileged, config, computer } = this.options
    try {
      // A helper outlives a stopped computer in its old namespace, so lan0 is looked for in the computer's.
      const running = (await docker(['inspect', '-f', '{{.State.Status}}', this.helper], 15_000).catch(() => '')).trim() === 'running'
      const present = await docker(['exec', computer, 'test', '-e', '/sys/class/net/lan0'], 10_000).then(() => true, () => false)
      if (!running || !present || !await this.address()) {
        await docker(['rm', '-f', this.helper], 60_000).catch(() => {})
        const pid = (await docker(['inspect', '-f', '{{.State.Pid}}', computer], 15_000)).trim()
        if (!/^[1-9]\d*$/.test(pid)) throw new Error(`${computer} is not running`)
        await privileged('ip', ['link', 'del', this.link]).catch(() => {})
        await privileged('ip', ['link', 'add', 'link', config.interface, 'name', this.link,
          ...(config.mode === 'macvlan' ? ['address', lanMac(computer), 'type', 'macvlan', 'mode', 'bridge'] : ['type', 'ipvlan', 'mode', 'l2'])])
        await privileged('ip', ['link', 'set', this.link, 'netns', pid])
        await docker(['run', '-d', '--name', this.helper, '--network', `container:${computer}`, '--restart', 'no',
          '--label', 'caboose.companion=lan', '--label', `caboose.computer=${computer}`,
          '--cap-drop', 'ALL', '--cap-add', 'NET_ADMIN', '--cap-add', 'NET_RAW', '--security-opt', 'no-new-privileges', '--memory', '64m', '--pids-limit', '50',
          '-e', `CABOOSE_LINK=${this.link}`, '-e', `CABOOSE_HOSTNAME=${this.options.hostname()}`, '-e', `CABOOSE_LAN_OUT=${config.allowOut ? 'allow' : 'deny'}`,
          '--entrypoint', '/bin/sh', config.image, '-c', LAN_SCRIPT], 300_000)
      }
      let address: string | undefined
      for (let attempt = 0; attempt < 60 && !(address = await this.address()); attempt++) await new Promise(resolve => setTimeout(resolve, 500))
      this.current = address
        ? { state: 'running', address, name: `${this.options.hostname()}.local` }
        : { state: 'error', error: `No DHCP lease on ${config.interface} after 30 s` }
    } catch (error) {
      this.current = { state: 'error', error: error instanceof Error ? error.message : String(error) }
    }
    return this.status
  }

  /** The lease is the helper's; it renews while the computer is parked. */
  async refresh(): Promise<LanStatus> {
    const address = await this.address()
    if (address) this.current = { state: 'running', address, name: `${this.options.hostname()}.local` }
    else if (this.current.state === 'running') this.current = { state: 'starting' }
    return this.status
  }

  async destroy(): Promise<void> {
    await this.options.docker(['rm', '-f', this.helper], 60_000).catch(() => {})
    await this.options.privileged('ip', ['link', 'del', this.link]).catch(() => {})
  }
}
