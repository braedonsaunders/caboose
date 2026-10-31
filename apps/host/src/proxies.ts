import type { IncomingMessage } from 'node:http'
import { isIP } from 'node:net'

/**
 * A range of addresses reverse proxies sit in, as a 128-bit network and prefix length.
 * IPv4 lives in the `::ffff:0:0/96` range, so one comparison serves both families and
 * a peer Node reports as `::ffff:203.0.113.9` matches the range `203.0.113.0/24`.
 */
export interface ProxyRange { network: bigint; bits: number }
export type TrustedProxies = readonly ProxyRange[]

const MAPPED_IPV4 = 0xffffn << 32n

/** The ranges every host trusts: a proxy on this machine can forward nothing a client invented. */
const LOOPBACK = parseTrustedProxies('127.0.0.0/8,::1')

/**
 * `CABOOSE_TRUSTED_PROXIES`: a comma-separated list of IPv4 or IPv6 addresses or CIDR
 * ranges. An address without a prefix length is that one address.
 */
export function parseTrustedProxies(value: string | undefined, name = 'CABOOSE_TRUSTED_PROXIES'): TrustedProxies {
  return (value ?? '').split(',').map(entry => entry.trim()).filter(Boolean).map(entry => {
    const [address = '', prefix, ...rest] = entry.split('/')
    const family = isIP(address)
    const width = family === 4 ? 32 : 128
    const length = prefix === undefined ? width : Number(prefix)
    if (!family || rest.length || (prefix !== undefined && !/^\d{1,3}$/.test(prefix)) || length > width) {
      throw new Error(`${name} must list IPv4 or IPv6 addresses or CIDR ranges separated by commas; "${entry}" is not one`)
    }
    const bits = family === 4 ? length + 96 : length
    return { network: addressBits(address)! & mask(bits), bits }
  })
}

/** Whether an address is loopback or in a configured range; an address that is not an IP never is. */
export function isTrustedProxy(address: string | undefined, trusted: TrustedProxies): boolean {
  const bits = address === undefined ? null : addressBits(address)
  if (bits === null) return false
  return [...LOOPBACK, ...trusted].some(range => (bits & mask(range.bits)) === range.network)
}

/**
 * The address a request came from: the TCP peer, or behind a trusted proxy the last hop
 * of `X-Forwarded-For` that is not itself a trusted proxy. Walking from the right trusts
 * only what trusted proxies appended; whatever a client put in the header stays to the
 * left of them. IPv4 reported through an IPv6 socket is written as plain IPv4, so one
 * client is one address however it connected.
 */
export function clientAddress(request: IncomingMessage, trusted: TrustedProxies): string {
  const peer = request.socket.remoteAddress ?? 'unknown'
  if (!isTrustedProxy(peer, trusted)) return canonical(peer)
  const hops = String(request.headers['x-forwarded-for'] ?? '').split(',').map(hop => hop.trim()).filter(Boolean)
  for (let index = hops.length - 1; index >= 0; index--) if (!isTrustedProxy(hops[index], trusted)) return canonical(hops[index]!)
  // Every hop is a proxy of ours: the leftmost is the one that started the request.
  return canonical(hops[0] ?? peer)
}

/**
 * The origin a browser sees this request at: the `Host` header, over HTTPS only when a
 * trusted proxy says so in `X-Forwarded-Proto`. Null without a `Host` header.
 */
export function requestOrigin(request: IncomingMessage, trusted: TrustedProxies): string | null {
  const host = request.headers.host
  if (!host) return null
  const forwarded = isTrustedProxy(request.socket.remoteAddress, trusted) ? String(request.headers['x-forwarded-proto'] ?? '').split(',')[0]?.trim() : undefined
  try { return new URL(`${forwarded === 'https' ? 'https' : 'http'}://${host}`).origin } catch { return null }
}

/**
 * Removes the forwarding headers of a peer that is not a trusted proxy. Better Auth reads
 * `X-Forwarded-Proto` to learn the browser's origin and cannot see the peer itself, so the
 * headers are gone before anything reads them.
 */
export function dropUntrustedForwarding(request: IncomingMessage, trusted: TrustedProxies): void {
  if (isTrustedProxy(request.socket.remoteAddress, trusted)) return
  for (const name of ['x-forwarded-for', 'x-forwarded-proto', 'x-forwarded-host']) delete request.headers[name]
}

/** An address as 128 bits (IPv4 mapped into `::ffff:0:0/96`), or null when the text is not an address. */
function addressBits(text: string): bigint | null {
  const address = text.replace(/%.*$/, '')
  const family = isIP(address)
  if (family === 4) return MAPPED_IPV4 | ipv4(address)
  if (family !== 6) return null
  const [head = '', tail] = address.split('::')
  const groups = (side: string): bigint[] => side ? side.split(':').flatMap(group => group.includes('.') ? [ipv4(group) >> 16n, ipv4(group) & 0xffffn] : [BigInt(`0x${group}`)]) : []
  const left = groups(head)
  const right = tail === undefined ? [] : groups(tail)
  return [...left, ...Array<bigint>(8 - left.length - right.length).fill(0n), ...right].reduce((value, group) => (value << 16n) | group, 0n)
}

function ipv4(text: string): bigint {
  return text.split('.').reduce((value, octet) => (value << 8n) | BigInt(octet), 0n)
}

/** The high `bits` of 128 set. */
function mask(bits: number): bigint {
  return bits === 0 ? 0n : ((1n << BigInt(bits)) - 1n) << BigInt(128 - bits)
}

/** Plain IPv4 for an IPv4 address reported through an IPv6 socket; anything else as given. */
function canonical(address: string): string {
  const bits = addressBits(address)
  if (bits === null || bits >> 32n !== 0xffffn) return address
  return [24n, 16n, 8n, 0n].map(shift => String((bits >> shift) & 0xffn)).join('.')
}
