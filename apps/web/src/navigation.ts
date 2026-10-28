import * as React from 'react'
import type { SidebarNavGroup } from '@braedonsaunders/appkit-ui'

export type RoutePath = '/' | '/settings' | '/agents'

export const NAVIGATION_GROUPS: SidebarNavGroup[] = [
  {
    id: 'overview',
    label: 'Overview',
    items: [
      {
        href: '/',
        label: 'Overview',
        iconKey: 'gauge',
        exact: true,
        mobile: true,
      },
    ],
  },
  {
    id: 'settings',
    label: 'Settings',
    items: [
      {
        href: '/settings',
        label: 'Settings',
        iconKey: 'settings',
        mobile: true,
      },
    ],
  },
  {
    id: 'agents',
    label: 'Agents',
    items: [
      {
        href: '/agents',
        label: 'Agents',
        iconKey: 'sparkles',
        mobile: true,
      },
    ],
  },
]

export function normalizePathname(raw: string): RoutePath {
  const clean = raw.split('?')[0]?.replace(/\/+$/, '') || '/'
  if (clean === '/settings' || clean.startsWith('/settings/')) return '/settings'
  if (clean === '/agents' || clean.startsWith('/agents/')) return '/agents'
  return '/'
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
