import * as React from 'react'
import type { SidebarNavGroup } from '@braedonsaunders/appkit-ui'
import { Building2, Gauge, Monitor, Server, Users } from 'lucide-react'

/** The computer's page is split into tabs, each with its own address. */
export type ComputerTab = 'overview' | 'files' | 'apps' | 'phones' | 'settings'

export type Route =
  | { page: 'overview' }
  | { page: 'computers' }
  | { page: 'computer'; id: string; tab: ComputerTab }
  | { page: 'people' }
  | { page: 'tenants' }
  | { page: 'host' }
  | { page: 'usage' }
  /** Pages outside the console: setting the host up, and accepting an invitation. */
  | { page: 'setup' }
  | { page: 'invite' }

export const COMPUTER_TABS: Array<{ key: ComputerTab; label: string }> = [
  { key: 'overview', label: 'Overview' },
  { key: 'files', label: 'Files' },
  { key: 'apps', label: 'Apps' },
  { key: 'phones', label: 'Phones' },
  { key: 'settings', label: 'Settings' },
]

const OWNER = 'owner'
const COMPUTER_ID = /^[a-z0-9-]{1,40}$/

/**
 * Addresses from earlier consoles, so bookmarks still land: the single-computer pages of
 * the first console, and the `/computer` page of the one before several computers.
 */
const LEGACY: Record<string, ComputerTab> = { '/apps': 'apps', '/files': 'files', '/devices': 'phones', '/settings': 'settings' }

const icon = (Icon: typeof Server) => React.createElement(Icon, { className: 'size-4', 'aria-hidden': true })

/**
 * The sidebar, one entry per group so it stays a flat list (appkit-ui's isFlatNavigation).
 * Tenants and Host are the operator's; a tenant's administrators see their own computers and
 * people.
 */
export function navigationGroups(operator: boolean): SidebarNavGroup[] {
  return [
    { href: '/', label: 'Overview', icon: icon(Gauge), exact: true, mobile: true },
    { href: '/computers', label: 'Computers', icon: icon(Monitor), mobile: true },
    { href: '/usage', label: 'Usage', icon: icon(Gauge), mobile: true },
    { href: '/people', label: 'People', icon: icon(Users), mobile: true },
    ...(operator ? [
      { href: '/tenants', label: 'Tenants', icon: icon(Building2), mobile: true },
      { href: '/host', label: 'Host', icon: icon(Server), mobile: true },
    ] : []),
  ].map(item => ({ id: item.href === '/' ? 'overview' : item.href.slice(1), label: item.label, items: [item] }))
}

function tabOf(value: string | undefined): ComputerTab {
  return COMPUTER_TABS.find(entry => entry.key !== 'overview' && entry.key === value)?.key ?? 'overview'
}

export function parseRoute(raw: string): Route {
  const clean = raw.split('?')[0]?.replace(/\/+$/, '') || '/'
  if (clean === '/host' || clean === '/system' || clean.startsWith('/system/')) return { page: 'host' }
  if (clean === '/computers') return { page: 'computers' }
  if (clean === '/people') return { page: 'people' }
  if (clean === '/usage') return { page: 'usage' }
  if (clean === '/tenants') return { page: 'tenants' }
  if (clean === '/setup') return { page: 'setup' }
  if (clean === '/invite') return { page: 'invite' }
  const [, section, id, tab] = clean.split('/')
  if (section === 'computers' && id) return COMPUTER_ID.test(id) ? { page: 'computer', id, tab: tabOf(tab) } : { page: 'computers' }
  if (section === 'computer' && clean.split('/').length <= 3) return { page: 'computer', id: OWNER, tab: tabOf(id) }
  const legacy = Object.keys(LEGACY).find(path => clean === path || clean.startsWith(`${path}/`))
  return legacy ? { page: 'computer', id: OWNER, tab: LEGACY[legacy]! } : { page: 'overview' }
}

export function routeHref(route: Route): string {
  switch (route.page) {
    case 'overview': return '/'
    case 'computers': return '/computers'
    case 'host': return '/host'
    case 'usage': return '/usage'
    case 'people': return '/people'
    case 'tenants': return '/tenants'
    case 'setup': return '/setup'
    case 'invite': return '/invite'
    case 'computer': {
      const base = `/computers/${encodeURIComponent(route.id)}`
      return route.tab === 'overview' ? base : `${base}/${route.tab}`
    }
  }
}

/** The address the sidebar highlights for a route: every computer's pages sit under Computers. */
export function sidebarPath(route: Route): string {
  return route.page === 'computer' ? '/computers' : routeHref(route)
}

export function navigate(href: string, options: { replace?: boolean } = {}): void {
  if (typeof window === 'undefined') return
  const target = href.startsWith('/') ? href : `/${href}`
  if (window.location.pathname + window.location.search === target) return
  if (options.replace) window.history.replaceState(null, '', target)
  else window.history.pushState(null, '', target)
  window.dispatchEvent(new PopStateEvent('popstate'))
}

export function useRoute(): Route {
  const [pathname, setPathname] = React.useState(() => typeof window !== 'undefined' ? window.location.pathname : '/')

  React.useEffect(() => {
    const onPopState = () => setPathname(window.location.pathname)
    window.addEventListener('popstate', onPopState)
    return () => window.removeEventListener('popstate', onPopState)
  }, [])

  const route = React.useMemo(() => parseRoute(pathname), [pathname])

  // A legacy or unknown address is rewritten to the page it shows, keeping its query (a Files folder).
  React.useEffect(() => {
    const canonical = routeHref(route)
    if (pathname !== canonical) navigate(canonical + window.location.search, { replace: true })
  }, [pathname, route])

  return route
}

/** A query parameter of the current URL, following back and forward. */
export function useSearchParam(name: string): string | null {
  const read = () => typeof window !== 'undefined' ? new URLSearchParams(window.location.search).get(name) : null
  const [value, setValue] = React.useState<string | null>(read)

  React.useEffect(() => {
    const onPopState = () => setValue(new URLSearchParams(window.location.search).get(name))
    window.addEventListener('popstate', onPopState)
    return () => window.removeEventListener('popstate', onPopState)
  }, [name])

  return value
}
