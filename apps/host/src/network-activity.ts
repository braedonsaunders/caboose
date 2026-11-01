import type { AgentGuest } from './agents.js'

/**
 * What the computer's own network namespace is doing, read from its /proc/net tables: the
 * servers it runs and the connections they hold. The tables are guest output, so every line
 * is parsed defensively and anything malformed is skipped.
 */
export interface NetworkSocket {
  protocol: 'tcp' | 'udp'
  local: { address: string; port: number }
  remote: { address: string; port: number }
  /** The kernel's state: 0x0A is a TCP listener, 0x01 an established connection, 0x07 an unconnected UDP socket. */
  state: number
}

export interface NetworkServer { protocol: 'tcp' | 'udp'; address: string; port: number }

export interface NetworkActivity {
  /** Servers another machine can reach: listening on an address that is not loopback. */
  servers: NetworkServer[]
  /** Established connections to the computer's servers from another machine. */
  connections: number
}

/** Caboose's own services in the computer (display, agent seat, files, terminal and their kin). */
export const CABOOSE_PORTS = { min: 14600, max: 14799 }
/** Discovery protocols every desktop answers on (mDNS, SSDP, LLMNR, NetBIOS); never a server the owner started. */
const DISCOVERY_PORTS = new Set([137, 138, 1900, 5353, 5355])

const TCP_LISTEN = 0x0a, TCP_ESTABLISHED = 0x01, UDP_UNCONNECTED = 0x07

/** A /proc/net address, `0100007F:1F90` or 32 hex digits of IPv6, each 32-bit word in host (little-endian) order. */
function address(field: string): { address: string; port: number } | null {
  const match = /^([0-9A-F]{8}|[0-9A-F]{32}):([0-9A-F]{4})$/i.exec(field)
  if (!match) return null
  const hex = match[1]!, port = parseInt(match[2]!, 16)
  const words = hex.match(/.{8}/g)!.map(word => word.match(/../g)!.reverse().join(''))
  if (words.length === 1) return { address: words[0]!.match(/../g)!.map(byte => parseInt(byte, 16)).join('.'), port }
  const groups = words.join('').match(/.{4}/g)!.map(group => group.replace(/^0+(?=.)/, '').toLowerCase())
  return { address: groups.join(':'), port }
}

/** Parses one of /proc/net/{tcp,tcp6,udp,udp6}. */
export function parseProcNet(text: string, protocol: 'tcp' | 'udp'): NetworkSocket[] {
  const sockets: NetworkSocket[] = []
  for (const line of text.split('\n').slice(1)) {
    const fields = line.trim().split(/\s+/)
    if (fields.length < 4) continue
    const local = address(fields[1]!), remote = address(fields[2]!)
    if (!local || !remote || !/^[0-9A-F]{2}$/i.test(fields[3]!)) continue
    sockets.push({ protocol, local, remote, state: parseInt(fields[3]!, 16) })
  }
  return sockets
}

/** 127.0.0.0/8, ::1, and IPv4-mapped loopback. */
export function isLoopback(value: string): boolean {
  const mapped = /^0:0:0:0:0:ffff:([0-9a-f]{1,4}):[0-9a-f]{1,4}$/.exec(value)
  if (mapped) return parseInt(mapped[1]!, 16) >> 8 === 127
  return value.startsWith('127.') || value === '0:0:0:0:0:0:0:1'
}

/** The unspecified address, as /proc/net writes it for a wildcard bind. */
function isAny(value: string): boolean { return value === '0.0.0.0' || value === '0:0:0:0:0:0:0:0' }

/**
 * The servers and outside connections among the computer's sockets. Caboose's own ports, ports
 * in the kernel's ephemeral range (what programs get when they ask for any port) and the
 * discovery protocols are not servers the owner runs.
 */
export function networkActivity(sockets: readonly NetworkSocket[], ephemeral: readonly [number, number] = [32768, 60999]): NetworkActivity {
  const ours = (port: number) => (port >= CABOOSE_PORTS.min && port <= CABOOSE_PORTS.max) || (port >= ephemeral[0] && port <= ephemeral[1])
  const servers = new Map<string, NetworkServer>()
  const listening = new Set<number>()
  for (const socket of sockets) {
    if (socket.protocol === 'tcp' && socket.state === TCP_LISTEN) listening.add(socket.local.port)
    const server = socket.protocol === 'tcp' ? socket.state === TCP_LISTEN
      : socket.state === UDP_UNCONNECTED && isAny(socket.remote.address) && socket.remote.port === 0 && !DISCOVERY_PORTS.has(socket.local.port)
    if (!server || isLoopback(socket.local.address) || ours(socket.local.port)) continue
    servers.set(`${socket.protocol}/${socket.local.port}`, { protocol: socket.protocol, address: socket.local.address, port: socket.local.port })
  }
  let connections = 0
  for (const socket of sockets) {
    if (socket.protocol !== 'tcp' || socket.state !== TCP_ESTABLISHED) continue
    if (!listening.has(socket.local.port) || CABOOSE_PORTS.min <= socket.local.port && socket.local.port <= CABOOSE_PORTS.max) continue
    if (!isLoopback(socket.remote.address)) connections++
  }
  return { servers: [...servers.values()].sort((a, b) => a.port - b.port || a.protocol.localeCompare(b.protocol)), connections }
}

/** Prints each table after a marker line, so one exec reads all of them. */
const READ_TABLES = 'for f in /proc/sys/net/ipv4/ip_local_port_range /proc/net/tcp /proc/net/tcp6 /proc/net/udp /proc/net/udp6; do echo "@@ $f"; cat "$f" 2>/dev/null; done'

/** Reads the running computer's sockets in one root exec. */
export async function readNetworkActivity(guest: AgentGuest, timeoutMs = 10_000): Promise<NetworkActivity> {
  const output = await guest.run('/bin/sh', ['-c', READ_TABLES], timeoutMs)
  const sections = new Map<string, string>()
  for (const part of output.split(/^@@ /m).slice(1)) {
    const newline = part.indexOf('\n')
    sections.set(part.slice(0, newline < 0 ? undefined : newline).trim(), newline < 0 ? '' : part.slice(newline + 1))
  }
  const range = /^\s*(\d+)\s+(\d+)\s*$/.exec(sections.get('/proc/sys/net/ipv4/ip_local_port_range') ?? '')
  const ephemeral: [number, number] = range ? [Number(range[1]), Number(range[2])] : [32768, 60999]
  const sockets = [
    ...parseProcNet(sections.get('/proc/net/tcp') ?? '', 'tcp'), ...parseProcNet(sections.get('/proc/net/tcp6') ?? '', 'tcp'),
    ...parseProcNet(sections.get('/proc/net/udp') ?? '', 'udp'), ...parseProcNet(sections.get('/proc/net/udp6') ?? '', 'udp'),
  ]
  return networkActivity(sockets, ephemeral)
}

/**
 * Whether the computer is in use as a network machine. A server another machine can reach
 * keeps it awake (it is not idle while a server runs), but only when the computer has an
 * address another machine can use; an outside connection always does.
 */
export function networkBusy(activity: NetworkActivity, reachable: boolean): boolean {
  return activity.connections > 0 || (reachable && activity.servers.length > 0)
}
