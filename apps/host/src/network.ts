import { execFile } from 'node:child_process'
import { promisify } from 'node:util'
import type { DeskHandle } from '@braedonsaunders/appkit-desk'

const exec = promisify(execFile)
const TAP = 'caboose0'
const HOST = '192.0.2.1'
export const GUEST_ADDRESS = '192.0.2.2'

// Bunkhouse's TAP setup is being upstreamed into appkit-desk. Keep this seam
// small so the package's network implementation can replace it once published.
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

/** Private, link-local (cloud metadata), CGNAT/Tailscale and reserved ranges. */
export const FENCED_RANGES = ['10.0.0.0/8', '172.16.0.0/12', '192.168.0.0/16', '169.254.0.0/16', '100.64.0.0/10',
  '127.0.0.0/8', '0.0.0.0/8', '192.0.0.0/24', '198.18.0.0/15', '224.0.0.0/4', '240.0.0.0/4']

/**
 * The rules that fence the guest, in order, for a chain the host owns outright. The guest
 * may open nothing on the host (the host opens the display relay itself; DNS is public and
 * the clock is set over vsock), and by default reaches only the public internet.
 */
export function fenceRules(guestLan: boolean): { input: string[][]; forward: string[][] } {
  const established = ['-m', 'conntrack', '--ctstate', 'ESTABLISHED,RELATED', '-j', 'RETURN']
  return {
    input: [established, ['-j', 'DROP']],
    forward: [
      established,
      ...(guestLan ? [] : FENCED_RANGES.map(range => ['-d', range, '-j', 'REJECT', '--reject-with', 'icmp-net-prohibited'])),
      ['-j', 'RETURN'],
    ],
  }
}

/** Creates (or refills) a chain and makes sure the built-in chain jumps to it first. */
async function ownChain(chain: string, from: 'INPUT' | 'FORWARD' | 'DOCKER-USER', rules: string[][], device = TAP): Promise<void> {
  if (!await exists('iptables', ['-N', chain])) await privileged('iptables', ['-F', chain])
  for (const args of rules) await privileged('iptables', ['-A', chain, ...args])
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

/** Persistent named TAP: it must exist before both boot and snapshot restore. */
export async function ensureNetwork(): Promise<void> {
  if (!await exists('ip', ['link', 'show', 'dev', TAP])) {
    const uid = process.getuid?.()
    if (uid === undefined) throw new Error('TAP networking requires Linux')
    await privileged('ip', ['tuntap', 'add', 'dev', TAP, 'mode', 'tap', 'user', String(uid)])
  }
  await privileged('ip', ['addr', 'replace', `${HOST}/30`, 'dev', TAP])
  await privileged('ip', ['link', 'set', 'dev', TAP, 'up'])
  await privileged('sysctl', ['-w', 'net.ipv4.ip_forward=1'])
  const fence = fenceRules(process.env.CABOOSE_GUEST_LAN === 'allow')
  await ownChain('CABOOSE-IN', 'INPUT', fence.input)
  await ownChain('CABOOSE-FWD', 'FORWARD', fence.forward)
  await rule('nat', 'POSTROUTING', ['-s', `${GUEST_ADDRESS}/32`, '!', '-o', TAP, '-j', 'MASQUERADE'])
  await rule('filter', 'FORWARD', ['-i', TAP, '-s', `${GUEST_ADDRESS}/32`, '-j', 'ACCEPT'])
  await rule('filter', 'FORWARD', ['-o', TAP, '-d', `${GUEST_ADDRESS}/32`, '-m', 'conntrack', '--ctstate', 'ESTABLISHED,RELATED', '-j', 'ACCEPT'])
}

export async function configureGuest(desk: DeskHandle): Promise<void> {
  const script = `set -eu\ndev=$(ls /sys/class/net | grep -E '^(en|eth)' | head -n 1)\ntest -n "$dev"\nip addr replace ${GUEST_ADDRESS}/30 dev "$dev"\nip link set dev "$dev" up\nip route replace default via ${HOST} dev "$dev"\nrm -f /etc/resolv.conf\nprintf 'nameserver 1.1.1.1\\n' > /etc/resolv.conf\ndate -u -s @${(Date.now() / 1000).toFixed(3)} >/dev/null`
  const result = await desk.exec({ command: '/bin/sh', args: ['-c', script], timeoutMs: 20_000 })
  if (result.exitCode !== 0) throw new Error(`Guest network/clock setup failed: ${result.stderr}`)
}
export const TAP_DEVICE = TAP
