import { execFile } from 'node:child_process'
import { promisify } from 'node:util'
import type { DeskHandle } from '@braedonsaunders/appkit-desk'

const exec = promisify(execFile)

/**
 * Every microVM computer gets its own point-to-point /30 in TEST-NET-1 (192.0.2.0/24): slot n
 * uses TAP `caboose<n>`, the host side .4n+1 and the guest .4n+2. Slot 0 is the owner's
 * computer, so a host from before several computers keeps `caboose0`, 192.0.2.1 and .2.
 */
export const COMPUTERS_SUBNET = '192.0.2.0/24'
export const EXPANDED_SUBNET = '198.18.0.0/15'
export const MAX_SLOTS = 64 + 32768

export interface NetworkSlot { tap: string; host: string; guest: string }

export function networkSlot(slot: number): NetworkSlot {
  if (!Number.isSafeInteger(slot) || slot < 0 || slot >= MAX_SLOTS) throw new Error(`Network slot must be an integer from 0 to ${MAX_SLOTS - 1}`)
  if (slot < 64) return { tap: `caboose${slot}`, host: `192.0.2.${slot * 4 + 1}`, guest: `192.0.2.${slot * 4 + 2}` }
  const offset = (slot - 64) * 4
  const prefix = `198.${18 + Math.floor(offset / 65536)}.${Math.floor(offset / 256) % 256}`
  return { tap: `caboose${slot}`, host: `${prefix}.${offset % 256 + 1}`, guest: `${prefix}.${offset % 256 + 2}` }
}

// Host networking for the microVMs: a TAP device per computer, its guest's address, and the
// fence that keeps every guest to the public internet. Commands run as root, or through `sudo -n`.
async function privileged(command: string, args: string[]): Promise<void> {
  const executable = process.getuid?.() === 0 ? command : 'sudo'
  const arguments_ = executable === 'sudo' ? ['-n', command, ...args] : args
  await exec(executable, arguments_, { timeout: 15_000 })
}
async function exists(command: string, args: string[]): Promise<boolean> {
  try { await privileged(command, args); return true } catch { return false }
}
async function rule(table: string, chain: string, args: string[]): Promise<void> {
  if (!await exists('iptables', ['-t', table, '-C', chain, ...args])) {
    await privileged('iptables', ['-t', table, '-A', chain, ...args])
  }
}
async function dropRule(table: string, chain: string, args: string[]): Promise<void> {
  while (await exists('iptables', ['-t', table, '-C', chain, ...args])) {
    await privileged('iptables', ['-t', table, '-D', chain, ...args])
  }
}

/** Private, link-local (cloud metadata), CGNAT/Tailscale and reserved ranges. */
export const FENCED_RANGES = ['10.0.0.0/8', '172.16.0.0/12', '192.168.0.0/16', '169.254.0.0/16', '100.64.0.0/10',
  '127.0.0.0/8', '0.0.0.0/8', '192.0.0.0/24', '198.18.0.0/15', '224.0.0.0/4', '240.0.0.0/4']

/**
 * The rules that fence a guest, in order, for a chain the host owns outright. The guest may
 * open nothing on the host (the host opens the display relay itself; DNS is public and the
 * clock is set over vsock), never reaches another computer, and by default reaches only the
 * public internet.
 */
export function fenceRules(guestLan: boolean): { input: string[][]; forward: string[][] } {
  const established = ['-m', 'conntrack', '--ctstate', 'ESTABLISHED,RELATED', '-j', 'RETURN']
  const reject = (range: string) => ['-d', range, '-j', 'REJECT', '--reject-with', 'icmp-net-prohibited']
  return {
    input: [established, ['-j', 'DROP']],
    forward: [
      established,
      // Other computers are other people's machines: allowing the LAN never opens them.
      reject(COMPUTERS_SUBNET),
      reject(EXPANDED_SUBNET),
      ...(guestLan ? [] : FENCED_RANGES.map(reject)),
      ['-j', 'RETURN'],
    ],
  }
}

/**
 * Creates a chain the host owns, fills it unless it already holds exactly these rules, and
 * makes sure the built-in chain jumps to it first for this device. A chain shared by several
 * computers is never emptied while it already fences a running one.
 */
async function ownChain(chain: string, from: 'INPUT' | 'FORWARD' | 'DOCKER-USER', rules: string[][], device: string): Promise<void> {
  const created = await exists('iptables', ['-N', chain])
  // Add the expanded inter-computer fence before checking existing rules; never
  // flush a live chain while migrating from the legacy allow-LAN policy.
  const expanded = ['-d', EXPANDED_SUBNET, '-j', 'REJECT', '--reject-with', 'icmp-net-prohibited']
  if (!created && from !== 'INPUT' && !await exists('iptables', ['-C', chain, ...expanded])) {
    await privileged('iptables', ['-I', chain, '2', ...expanded])
  }
  let current = !created
  if (current) {
    for (const args of rules) if (!await exists('iptables', ['-C', chain, ...args])) { current = false; break }
  }
  if (!current) {
    if (!created) await privileged('iptables', ['-F', chain])
    for (const args of rules) await privileged('iptables', ['-A', chain, ...args])
  }
  if (!await exists('iptables', ['-C', from, '-i', device, '-j', chain])) {
    await privileged('iptables', ['-I', from, '1', '-i', device, '-j', chain])
  }
}

/**
 * The same fence for a container computer's bridge: nothing new to the host, and only the
 * public internet beyond it. Docker forwards container traffic through DOCKER-USER, which
 * it never rewrites, so the forward fence goes there.
 */
export async function fenceBridge(device: string): Promise<void> {
  const fence = fenceRules(process.env.CABOOSE_GUEST_LAN === 'allow')
  await ownChain('CABOOSE-CIN', 'INPUT', fence.input, device)
  await ownChain('CABOOSE-CFWD', 'DOCKER-USER', fence.forward, device)
}

/** Takes a container bridge's jumps out of the shared chains when its computer is deleted. */
export async function unfenceBridge(device: string): Promise<void> {
  await dropRule('filter', 'INPUT', ['-i', device, '-j', 'CABOOSE-CIN'])
  await dropRule('filter', 'DOCKER-USER', ['-i', device, '-j', 'CABOOSE-CFWD'])
}

/** Persistent named TAP: it must exist before both boot and snapshot restore. */
export async function ensureNetwork(slot = 0): Promise<void> {
  const { tap, host, guest } = networkSlot(slot)
  if (!await exists('ip', ['link', 'show', 'dev', tap])) {
    const uid = process.getuid?.()
    if (uid === undefined) throw new Error('TAP networking requires Linux')
    await privileged('ip', ['tuntap', 'add', 'dev', tap, 'mode', 'tap', 'user', String(uid)])
  }
  await privileged('ip', ['addr', 'replace', `${host}/30`, 'dev', tap])
  await privileged('ip', ['link', 'set', 'dev', tap, 'up'])
  await privileged('sysctl', ['-w', 'net.ipv4.ip_forward=1'])
  const fence = fenceRules(process.env.CABOOSE_GUEST_LAN === 'allow')
  await ownChain('CABOOSE-IN', 'INPUT', fence.input, tap)
  await ownChain('CABOOSE-FWD', 'FORWARD', fence.forward, tap)
  await rule('nat', 'POSTROUTING', ['-s', `${guest}/32`, '!', '-o', tap, '-j', 'MASQUERADE'])
  await rule('filter', 'FORWARD', ['-i', tap, '-s', `${guest}/32`, '-j', 'ACCEPT'])
  await rule('filter', 'FORWARD', ['-o', tap, '-d', `${guest}/32`, '-m', 'conntrack', '--ctstate', 'ESTABLISHED,RELATED', '-j', 'ACCEPT'])
}

/** Removes a deleted computer's TAP and its rules; the shared chains stay for the others. */
export async function removeNetwork(slot: number): Promise<void> {
  const { tap, guest } = networkSlot(slot)
  await dropRule('filter', 'INPUT', ['-i', tap, '-j', 'CABOOSE-IN'])
  await dropRule('filter', 'FORWARD', ['-i', tap, '-j', 'CABOOSE-FWD'])
  await dropRule('nat', 'POSTROUTING', ['-s', `${guest}/32`, '!', '-o', tap, '-j', 'MASQUERADE'])
  await dropRule('filter', 'FORWARD', ['-i', tap, '-s', `${guest}/32`, '-j', 'ACCEPT'])
  await dropRule('filter', 'FORWARD', ['-o', tap, '-d', `${guest}/32`, '-m', 'conntrack', '--ctstate', 'ESTABLISHED,RELATED', '-j', 'ACCEPT'])
  if (await exists('ip', ['link', 'show', 'dev', tap])) await privileged('ip', ['link', 'del', 'dev', tap])
}

export async function configureGuest(desk: DeskHandle, slot = 0, network?: { host: string; guest: string; prefix: number }): Promise<void> {
  const { host, guest } = network ?? networkSlot(slot)
  const prefix = network?.prefix ?? 30
  const script = `set -eu\ndev=$(ls /sys/class/net | grep -E '^(en|eth)' | head -n 1)\ntest -n "$dev"\nip addr replace ${guest}/${prefix} dev "$dev"\nip link set dev "$dev" up\nip route replace default via ${host} dev "$dev"\nrm -f /etc/resolv.conf\nprintf 'nameserver 1.1.1.1\\n' > /etc/resolv.conf\ndate -u -s @${(Date.now() / 1000).toFixed(3)} >/dev/null`
  const result = await desk.exec({ command: '/bin/sh', args: ['-c', script], timeoutMs: 20_000 })
  if (result.exitCode !== 0) throw new Error(`Guest network/clock setup failed: ${result.stderr}`)
}
