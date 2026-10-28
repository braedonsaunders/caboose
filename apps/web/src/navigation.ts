import * as React from 'react'
import type { SidebarNavGroup } from '@braedonsaunders/appkit-ui'
import { Bell, Folder, LayoutGrid, Server } from 'lucide-react'

export type RoutePath = '/' | '/apps' | '/files' | '/agents' | '/devices' | '/system' | '/settings'

const ROUTES: RoutePath[] = ['/apps', '/files', '/agents', '/devices', '/system', '/settings']

export const NAVIGATION_GROUPS: SidebarNavGroup[] = [
  {
    id: 'computer',
    label: 'Computer',
    items: [
      { href: '/', label: 'Overview', iconKey: 'gauge', exact: true, mobile: true },
      { href: '/apps', label: 'Apps', icon: React.createElement(LayoutGrid, { className: 'size-4', 'aria-hidden': true }), mobile: true },
      { href: '/files', label: 'Files', icon: React.createElement(Folder, { className: 'size-4', 'aria-hidden': true }), mobile: true },
      { href: '/agents', label: 'Agents', iconKey: 'sparkles', mobile: true },
    ],
  },
  {
    id: 'host',
    label: 'Host',
    items: [
      { href: '/devices', label: 'Devices', icon: React.createElement(Bell, { className: 'size-4', 'aria-hidden': true }) },
      { href: '/system', label: 'System', icon: React.createElement(Server, { className: 'size-4', 'aria-hidden': true }) },
      { href: '/settings', label: 'Settings', iconKey: 'settings', mobile: true },
    ],
  },
]

export function normalizePathname(raw: string): RoutePath {
  const clean = raw.split('?')[0]?.replace(/\/+$/, '') || '/'
  return ROUTES.find(route => clean === route || clean.startsWith(`${route}/`)) ?? '/'
}

export function navigate(href: string): void {
  if (typeof window === 'undefined') return
  const target = href.startsWith('/') ? href : `/${href}`
  if (window.location.pathname + window.location.search === target) return
  window.history.pushState(null, '', target)
  window.dispatchEvent(new PopStateEvent('popstate'))
}

export function usePathname(): RoutePath {
  const [pathname, setPathname] = React.useState<RoutePath>(() =>
    typeof window !== 'undefined' ? normalizePathname(window.location.pathname) : '/',
  )

  React.useEffect(() => {
    const onPopState = () => setPathname(normalizePathname(window.location.pathname))
    window.addEventListener('popstate', onPopState)
    return () => window.removeEventListener('popstate', onPopState)
  }, [])

  return pathname
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
