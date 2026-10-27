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
