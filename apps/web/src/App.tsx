import * as React from 'react'
import { AppShell, Button, ConfirmRoot, PromptRoot, Toaster, type LinkRender } from '@braedonsaunders/appkit-ui'
import { LogOut } from 'lucide-react'
import { CabooseClient, readSessionToken, writeSessionToken } from './api.js'
import { NAVIGATION_GROUPS, navigate, sidebarPath, useRoute } from './navigation.js'
import { useComputer } from './useComputer.js'
import { useHost } from './useHost.js'
import { Wordmark } from './brand/Logo.js'
import { SignIn } from './pages/SignIn.js'
import { Overview } from './pages/Overview.js'
import { Computer } from './pages/Computer.js'
import { Host } from './pages/Host.js'

/** Every navigation entry routes client-side, so the shell never reloads the page. */
const linkRender: LinkRender = ({ href, children, className, title, ariaCurrent, role }) => (
  <a
    href={href}
    className={className}
    title={title}
    aria-current={ariaCurrent}
    role={role}
    onClick={event => {
      if (event.metaKey || event.ctrlKey || event.shiftKey || event.button !== 0) return
      event.preventDefault()
      navigate(href)
    }}
  >
    {children}
  </a>
)

export function App() {
  const [token, setToken] = React.useState(() => readSessionToken())
  const signIn = React.useCallback((value: string) => {
    writeSessionToken(value)
    setToken(value.trim())
  }, [])
  const signOut = React.useCallback(() => {
    writeSessionToken('')
    setToken('')
  }, [])

  return (
    <>
      {token ? <Console token={token} onSignOut={signOut} /> : <SignIn onSignIn={signIn} />}
      <ConfirmRoot />
      <PromptRoot />
      <Toaster richColors />
    </>
  )
}

function Console({ token, onSignOut }: { token: string; onSignOut: () => void }) {
  const route = useRoute()
  const client = React.useMemo(() => new CabooseClient(() => token), [token])
  const computer = useComputer(client, onSignOut)
  const host = useHost(client, onSignOut)
  const name = computer.status?.settings.name ?? 'Caboose'

  React.useEffect(() => {
    document.title = route.page === 'computer' ? `${name} — Caboose` : route.page === 'host' ? 'Host — Caboose' : 'Caboose'
  }, [name, route.page])

  return (
    <AppShell
      groups={NAVIGATION_GROUPS}
      pathname={sidebarPath(route)}
      navigationMode="sidebar"
      linkRender={linkRender}
      brand={
        // The hubs are lit while the computer is up and unlit while it is parked.
        <Wordmark height={30} lit={computer.status?.state !== 'parked'} className="text-fg" />
      }
      header={
        <Button variant="ghost" size="sm" onClick={onSignOut}>
          <LogOut className="size-4" aria-hidden />
          Sign out
        </Button>
      }
    >
      {route.page === 'overview' ? <Overview computer={computer} host={host} /> : null}
      {route.page === 'computer'
        ? <Computer client={client} computer={computer} host={host} tab={route.tab} token={token} onUnauthorized={onSignOut} />
        : null}
      {route.page === 'host' ? <Host host={host} /> : null}
    </AppShell>
  )
}
