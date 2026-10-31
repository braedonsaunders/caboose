import type { IncomingMessage } from 'node:http'
import { requestOrigin, type TrustedProxies } from './proxies.js'

/** Methods that change nothing, so a cross-site page gains nothing from them. */
const SAFE_METHODS = new Set(['GET', 'HEAD', 'OPTIONS'])

export interface CrossSiteOptions {
  trustedProxies: TrustedProxies
  /** `CABOOSE_PUBLIC_URL`: the console's other origin behind a proxy that rewrites `Host`. */
  publicUrl?: string | null
  /** A WebSocket upgrade: a long-lived channel, checked whatever its method. */
  upgrade?: boolean
}

/**
 * Whether a request carrying a browser session must be refused as cross-site. A page on
 * another site can make the browser send the session cookie (SameSite=Lax still passes it
 * on top-level navigations and WebSocket handshakes), but cannot make the browser lie
 * about where the request came from: `Sec-Fetch-Site` and `Origin` are the browser's own.
 * One of them must vouch for the request. Bearer tokens need no check, since another site
 * cannot attach them; reads need none, since they change nothing.
 */
export function crossSite(request: IncomingMessage, principal: { kind: 'owner' | 'admin' | 'phone' } | undefined, options: CrossSiteOptions): boolean {
  if (principal?.kind !== 'admin') return false
  if (!options.upgrade && SAFE_METHODS.has(request.method ?? 'GET')) return false
  const site = request.headers['sec-fetch-site']
  if (site === 'same-origin' || site === 'none') return false
  const origin = originOf(request.headers.origin)
  if (!origin) return true
  return origin !== requestOrigin(request, options.trustedProxies) && origin !== originOf(options.publicUrl)
}

/** A URL's origin, normalized (default ports dropped), or null for anything that is not one, such as `null`. */
function originOf(value: string | null | undefined): string | null {
  if (!value) return null
  try { return new URL(value).origin } catch { return null }
}
