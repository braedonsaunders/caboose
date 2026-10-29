import { lookup } from 'node:dns/promises'
import type { IncomingMessage } from 'node:http'
import { request } from 'node:https'
import { BlockList, isIP } from 'node:net'

/**
 * HTTPS to hosts named by untrusted metadata (the MCP Registry, its icons, MCP servers). Every
 * address a name resolves to must be public, and the connection is pinned to the address that
 * was checked, so a second resolution cannot rebind it to the host's own network. Redirects
 * are refused, and bodies, streams and time are bounded.
 */
const BLOCKED = new BlockList()
for (const [address, prefix] of [
  ['0.0.0.0', 8], ['10.0.0.0', 8], ['100.64.0.0', 10], ['127.0.0.0', 8], ['169.254.0.0', 16], ['172.16.0.0', 12],
  ['192.0.0.0', 24], ['192.0.2.0', 24], ['192.88.99.0', 24], ['192.168.0.0', 16], ['198.18.0.0', 15], ['198.51.100.0', 24],
  ['203.0.113.0', 24], ['224.0.0.0', 4], ['240.0.0.0', 4],
] as const) BLOCKED.addSubnet(address, prefix, 'ipv4')
for (const [address, prefix] of [
  // IPv4 inside IPv6 (::ffff:0:0/96, 64:ff9b::/96) is refused before this list is asked; a
  // BlockList holding those prefixes would match every IPv4 address checked against it.
  ['::', 128], ['::1', 128], ['64:ff9b:1::', 48], ['100::', 64], ['2001::', 23],
  ['2001:db8::', 32], ['2002::', 16], ['fc00::', 7], ['fe80::', 10], ['fec0::', 10], ['ff00::', 8],
] as const) BLOCKED.addSubnet(address, prefix, 'ipv6')

export class UnsafeAddressError extends Error {}

/** The IPv4 address an IPv4-mapped or -translated IPv6 address carries, else null. */
function embeddedIPv4(address: string): string | null {
  const lower = address.toLowerCase()
  const dotted = /^(?:::ffff:|64:ff9b::)(\d+\.\d+\.\d+\.\d+)$/.exec(lower)
  if (dotted) return dotted[1]!
  const hex = /^(?:::ffff:|64:ff9b::)([0-9a-f]{1,4}):([0-9a-f]{1,4})$/.exec(lower)
  if (!hex) return null
  const high = parseInt(hex[1]!, 16), low = parseInt(hex[2]!, 16)
  return `${high >> 8}.${high & 255}.${low >> 8}.${low & 255}`
}

/** Whether an address is on the public internet: not private, loopback, link-local, shared or reserved. */
export function isPublicAddress(address: string): boolean {
  const family = isIP(address)
  if (family === 4) return !BLOCKED.check(address, 'ipv4')
  if (family !== 6) return false
  // An IPv4 address inside IPv6 (mapped or translated) never counts as public: whichever
  // address it carries, the route to it is the host's own.
  if (embeddedIPv4(address)) return false
  return !BLOCKED.check(address, 'ipv6')
}

export type Resolver = (host: string) => Promise<Array<{ address: string; family: number }>>
const resolveAll: Resolver = host => lookup(host, { all: true, verbatim: true })

/** One address for the host, after every address it has was checked. */
export async function publicAddress(host: string, resolve: Resolver = resolveAll): Promise<{ address: string; family: number }> {
  const bare = host.replace(/^\[|\]$/g, '')
  const addresses = isIP(bare) ? [{ address: bare, family: isIP(bare) }] : await resolve(bare).catch(() => [])
  if (!addresses.length) throw new UnsafeAddressError(`${host} could not be found`)
  if (!addresses.every(entry => isPublicAddress(entry.address))) throw new UnsafeAddressError(`${host} is not on the public internet`)
  return addresses[0]!
}

export interface SafeRequest { method?: 'GET' | 'POST' | 'PUT' | 'DELETE'; headers?: Record<string, string>; body?: string; timeoutMs?: number }
export interface SafeResponse { status: number; headers: Record<string, string | string[] | undefined>; body: Buffer }

/** Validates a URL from untrusted metadata: HTTPS on the default or a named port, no credentials. */
export function safeUrl(value: string): URL {
  let url: URL
  try { url = new URL(value) } catch { throw new UnsafeAddressError('Not a valid URL') }
  if (url.protocol !== 'https:' || url.username || url.password || value.length > 2000) throw new UnsafeAddressError('Only plain https addresses are allowed')
  return url
}

/** Opens an HTTPS response; the caller owns the stream. Redirects are refused. */
export async function openSafe(value: string, init: SafeRequest = {}, resolve: Resolver = resolveAll): Promise<{ response: IncomingMessage; abort: () => void }> {
  const url = safeUrl(value)
  const pinned = await publicAddress(url.hostname, resolve)
  return new Promise((resolvePromise, reject) => {
    const outgoing = request({
      protocol: 'https:', hostname: url.hostname, port: url.port || 443, path: `${url.pathname}${url.search}`, method: init.method ?? 'GET',
      headers: { 'user-agent': 'caboose-host', ...init.headers, ...(init.body ? { 'content-length': Buffer.byteLength(init.body) } : {}) },
      // The connection goes to the address that was checked, never to a second resolution.
      lookup: (_host, options, callback) => {
        if ((options as { all?: boolean }).all) (callback as unknown as (error: null, addresses: Array<{ address: string; family: number }>) => void)(null, [pinned])
        else callback(null, pinned.address, pinned.family)
      },
      timeout: init.timeoutMs ?? 20_000,
    }, response => {
      if ((response.statusCode ?? 0) >= 300 && (response.statusCode ?? 0) < 400) {
        response.destroy()
        reject(new UnsafeAddressError(`${url.hostname} redirected the request, which Caboose does not follow`))
        return
      }
      resolvePromise({ response, abort: () => { outgoing.destroy(); response.destroy() } })
    })
    outgoing.on('timeout', () => outgoing.destroy(new Error(`${url.hostname} did not answer in time`)))
    outgoing.on('error', reject)
    outgoing.end(init.body)
  })
}

/** A whole HTTPS response of at most `max` bytes, read within the time limit. */
export async function fetchSafe(value: string, max: number, init: SafeRequest = {}, resolve: Resolver = resolveAll): Promise<SafeResponse> {
  const { response, abort } = await openSafe(value, init, resolve)
  const deadline = setTimeout(abort, init.timeoutMs ?? 20_000)
  deadline.unref()
  try {
    const chunks: Buffer[] = []
    let size = 0
    for await (const chunk of response as AsyncIterable<Buffer>) {
      size += chunk.length
      if (size > max) { abort(); throw new Error(`${new URL(value).hostname} sent more than ${max} bytes`) }
      chunks.push(chunk)
    }
    return { status: response.statusCode ?? 0, headers: response.headers, body: Buffer.concat(chunks) }
  } finally { clearTimeout(deadline) }
}
