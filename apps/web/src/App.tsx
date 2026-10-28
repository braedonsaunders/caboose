import * as React from 'react'
import { AppShell, Button, ConfirmRoot, PromptRoot, Toaster, type LinkRender } from '@braedonsaunders/appkit-ui'
import { LogOut } from 'lucide-react'
import { CabooseClient, readSessionToken, writeSessionToken } from './api.js'
import { NAVIGATION_GROUPS, navigate, sidebarPath, useRoute } from './navigation.js'
import { useComputers } from './useComputer.js'
import { useHost } from './useHost.js'
import { Wordmark } from './brand/Logo.js'
import { SignIn } from './pages/SignIn.js'
import { Overview } from './pages/Overview.js'
import { Computer } from './pages/Computer.js'
import { Computers } from './pages/Computers.js'
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
  const computers = useComputers(client, onSignOut)
  const host = useHost(client, onSignOut)
  const awake = computers.list?.computers.some(computer => computer.state !== 'parked') ?? false

  React.useEffect(() => {
    if (route.page === 'host') document.title = 'Host — Caboose'
    else if (route.page === 'computers') document.title = 'Computers — Caboose'
    else if (route.page === 'overview') document.title = 'Caboose'
  }, [route.page])

  return (
    <AppShell
      groups={NAVIGATION_GROUPS}
      pathname={sidebarPath(route)}
      navigationMode="sidebar"
      linkRender={linkRender}
      brand={
        // The hubs are lit while any computer is up and unlit while every one is parked.
        <Wordmark height={30} lit={awake} className="text-fg" />
      }
      header={
        <Button variant="ghost" size="sm" onClick={onSignOut}>
          <LogOut className="size-4" aria-hidden />
          Sign out
        </Button>
      }
    >
      {route.page === 'overview' ? <Overview computers={computers} host={host} /> : null}
      {route.page === 'computers' ? <Computers client={client} computers={computers} /> : null}
      {route.page === 'computer' ? (
        // Keyed by computer, so nothing one computer's tabs loaded is shown for another.
        <Computer key={route.id} client={client} computers={computers} id={route.id} host={host} tab={route.tab} onUnauthorized={onSignOut} />
      ) : null}
      {route.page === 'host' ? <Host host={host} /> : null}
    </AppShell>
  )
}
