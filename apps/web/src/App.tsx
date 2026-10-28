import * as React from 'react'
import { AppShell, Button, ConfirmRoot, Toaster, type LinkRender } from '@braedonsaunders/appkit-ui'
import { LogOut, TrainFront } from 'lucide-react'
import { CabooseClient, readSessionToken, writeSessionToken } from './api.js'
import { NAVIGATION_GROUPS, navigate, usePathname } from './navigation.js'
import { useComputer } from './useComputer.js'
import { SignIn } from './pages/SignIn.js'
import { Overview } from './pages/Overview.js'
import { Settings } from './pages/Settings.js'
import { Agents } from './pages/Agents.js'

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
      <Toaster richColors />
    </>
  )
}

function Console({ token, onSignOut }: { token: string; onSignOut: () => void }) {
  const pathname = usePathname()
  const client = React.useMemo(() => new CabooseClient(() => token), [token])
  const computer = useComputer(client, onSignOut)
  const name = computer.status?.settings.name ?? 'Caboose'

  React.useEffect(() => { document.title = `${name} — Caboose` }, [name])

  return (
    <AppShell
      groups={NAVIGATION_GROUPS}
      pathname={pathname}
      navigationMode="sidebar"
      linkRender={linkRender}
      brand={
        <span className="flex items-center gap-2 font-semibold">
          <TrainFront className="size-5" aria-hidden />
          <span className="truncate">{name}</span>
        </span>
      }
      header={
        <Button variant="ghost" size="sm" onClick={onSignOut}>
          <LogOut className="size-4" aria-hidden />
          Sign out
        </Button>
      }
    >
      {pathname === '/settings' ? <Settings client={client} computer={computer} /> : null}
      {pathname === '/agents' ? <Agents client={client} computer={computer} onUnauthorized={onSignOut} /> : null}
      {pathname === '/' ? <Overview client={client} computer={computer} token={token} /> : null}
    </AppShell>
  )
}
