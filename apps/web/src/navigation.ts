import * as React from 'react'
import type { SidebarNavGroup } from '@braedonsaunders/appkit-ui'
import { Gauge, Monitor, Server } from 'lucide-react'

/** The computer's page is split into tabs, each with its own address. */
export type ComputerTab = 'overview' | 'files' | 'apps' | 'phones' | 'settings'

export type Route =
  | { page: 'overview' }
  | { page: 'computer'; tab: ComputerTab }
  | { page: 'host' }

export const COMPUTER_TABS: Array<{ key: ComputerTab; label: string }> = [
  { key: 'overview', label: 'Overview' },
  { key: 'files', label: 'Files' },
  { key: 'apps', label: 'Apps' },
  { key: 'phones', label: 'Phones' },
  { key: 'settings', label: 'Settings' },
]

/** Addresses from before the console was split into host and computer pages, so bookmarks still land. */
const LEGACY: Record<string, Route> = {
  '/apps': { page: 'computer', tab: 'apps' },
  '/files': { page: 'computer', tab: 'files' },
  '/devices': { page: 'computer', tab: 'phones' },
  '/settings': { page: 'computer', tab: 'settings' },
  '/system': { page: 'host' },
}

const icon = (Icon: typeof Server) => React.createElement(Icon, { className: 'size-4', 'aria-hidden': true })

/** One entry per group, so the sidebar stays a flat list (appkit-ui's isFlatNavigation). */
export const NAVIGATION_GROUPS: SidebarNavGroup[] = [
  { href: '/', label: 'Overview', icon: icon(Gauge), exact: true, mobile: true },
  { href: '/computer', label: 'Computer', icon: icon(Monitor), mobile: true },
  { href: '/host', label: 'Host', icon: icon(Server), mobile: true },
].map(item => ({ id: item.href === '/' ? 'overview' : item.href.slice(1), label: item.label, items: [item] }))

export function parseRoute(raw: string): Route {
  const clean = raw.split('?')[0]?.replace(/\/+$/, '') || '/'
  if (clean === '/host') return { page: 'host' }
  if (clean === '/computer') return { page: 'computer', tab: 'overview' }
  if (clean.startsWith('/computer/')) {
    const tab = COMPUTER_TABS.find(entry => entry.key !== 'overview' && clean === `/computer/${entry.key}`)
    return { page: 'computer', tab: tab?.key ?? 'overview' }
  }
  const legacy = Object.keys(LEGACY).find(path => clean === path || clean.startsWith(`${path}/`))
  return legacy ? LEGACY[legacy]! : { page: 'overview' }
}

export function routeHref(route: Route): string {
  switch (route.page) {
    case 'overview': return '/'
    case 'host': return '/host'
    case 'computer': return route.tab === 'overview' ? '/computer' : `/computer/${route.tab}`
  }
}

/** The address the sidebar highlights for a route. */
export function sidebarPath(route: Route): string {
  return route.page === 'computer' ? '/computer' : routeHref(route)
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
