import type { Reach } from './api.js'

type Kind = Reach['addresses'][number]['kind']

function isLoopback(url: string): boolean {
  try {
    const host = new URL(url).hostname
    return host === 'localhost' || host.startsWith('127.') || host === '[::1]' || host === '::1'
  } catch {
    return true
  }
}

/**
 * The addresses a pairing link carries, best first: the host's own list, and the address this
 * console was opened at when a phone could use it too. An HTTPS address the host does not know
 * about (a proxy in front of it) goes first; loopback never goes at all.
 */
export function pairingAddresses(reach: Reach | null, consoleOrigin: string): string[] {
  const listed = (reach?.addresses ?? []).map(address => address.url.replace(/\/+$/, ''))
  const origin = consoleOrigin.replace(/\/+$/, '')
  if (isLoopback(origin) || listed.includes(origin)) return listed
  return origin.startsWith('https:') ? [origin, ...listed] : [...listed, origin]
}

export function addressLabel(kind: Kind): string {
  switch (kind) {
    case 'public': return 'Your domain'
    case 'tailscale': return 'Tailscale'
    case 'lan': return 'Local network'
  }
}

export interface Guidance {
  tone: 'success' | 'info' | 'warning'
  title: string
  detail: string
  link?: { href: string; label: string }
}

const TAILSCALE_DOWNLOAD = 'https://tailscale.com/download'
const TAILSCALE_DNS = 'https://login.tailscale.com/admin/dns'

/** What the Tailscale row says, and the one thing to do next. */
export function tailscaleGuidance(tailscale: Reach['tailscale']): Guidance {
  if (!tailscale.installed) {
    return {
      tone: 'info', title: 'Tailscale is not installed on this machine',
      detail: 'Install Tailscale here and on your iPhone and sign both in to the same tailnet. Caboose can then be reached securely from anywhere, with no port forwarding.',
      link: { href: TAILSCALE_DOWNLOAD, label: 'Get Tailscale' },
    }
  }
  if (!tailscale.loggedIn) {
    return { tone: 'warning', title: 'Tailscale is signed out', detail: `${tailscale.error ?? 'Tailscale is not running'}. Sign in to Tailscale on this machine, then come back.` }
  }
  if (tailscale.serving && tailscale.httpsUrl) {
    return { tone: 'success', title: 'Reachable through Tailscale', detail: `Devices on your tailnet reach Caboose at ${tailscale.httpsUrl}, over HTTPS.` }
  }
  if (tailscale.error) {
    return {
      tone: 'warning', title: 'Tailscale cannot serve Caboose yet', detail: tailscale.error,
      ...(tailscale.error.includes(TAILSCALE_DNS) ? { link: { href: TAILSCALE_DNS, label: 'Open the tailnet DNS settings' } } : {}),
    }
  }
  return {
    tone: 'info', title: 'Tailscale is ready',
    detail: `Turn it on to reach Caboose at https://${tailscale.name ?? 'this machine'} from any device on your tailnet.`,
  }
}

/** Whether a phone away from home can reach the host, and if not, how it could. */
export function awayFromHome(reach: Reach): Guidance {
  if (reach.addresses.some(address => address.kind === 'public')) {
    return { tone: 'success', title: 'Reachable from anywhere', detail: 'Phones reach this host at its own domain over HTTPS.' }
  }
  if (reach.addresses.some(address => address.kind === 'tailscale')) {
    return { tone: 'success', title: 'Reachable from anywhere on your tailnet', detail: 'Phones signed in to Tailscale reach this host over HTTPS.' }
  }
  if (!reach.addresses.length) {
    return {
      tone: 'warning', title: 'Only this machine can reach Caboose',
      detail: 'The host listens on loopback. Set CABOOSE_BIND=0.0.0.0 and restart it so phones on your network can reach it, or turn on Tailscale below.',
    }
  }
  return {
    tone: 'info', title: 'Reachable on your local network',
    detail: 'Away from home, phones need Tailscale (below), or a domain with HTTPS (deploy/server). Never forward this port from your router: the network traffic is plain HTTP.',
  }
}
