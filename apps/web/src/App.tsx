import * as React from 'react'
import { AccountMenu, Alert, AlertDescription, AlertTitle, Button, AppShell, ConfirmRoot, PromptRoot, Toaster, type LinkRender } from '@braedonsaunders/appkit-ui'
import { CabooseApiError, CabooseClient, readSessionToken, writeSessionToken, type Me } from './api.js'
import { navigate, navigationGroups, sidebarPath, useRoute } from './navigation.js'
import { useComputers } from './useComputer.js'
import { useHost } from './useHost.js'
import { Wordmark, RollingWordmark } from './brand/Logo.js'
import { SignIn } from './pages/SignIn.js'
import { Setup } from './pages/Setup.js'
import { AcceptInvite } from './pages/AcceptInvite.js'
import { Overview } from './pages/Overview.js'
import { Computer } from './pages/Computer.js'
import { Computers } from './pages/Computers.js'
import { People } from './pages/People.js'
import { Tenants } from './pages/Tenants.js'
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

/**
 * How the console is signed in: an administrator's account (a session cookie the host set),
 * or the owner token, kept for this tab only and sent as a header.
 */
type Session = { kind: 'account' } | { kind: 'token'; token: string }

export function App() {
  const route = useRoute()
  const [session, setSession] = React.useState<Session | null | 'checking'>(() => {
    const token = readSessionToken()
    return token ? { kind: 'token', token } : 'checking'
  })

  // Without a token, a session cookie from an earlier sign-in may still be good.
  React.useEffect(() => {
    if (session !== 'checking') return
    new CabooseClient(() => '').me().then(
      () => setSession({ kind: 'account' }),
      () => setSession(null),
    )
  }, [session])

  const signedIn = React.useCallback((next: Session) => {
    writeSessionToken(next.kind === 'token' ? next.token : '')
    setSession(next)
  }, [])
  const signOut = React.useCallback(() => {
    if (session && session !== 'checking' && session.kind === 'account') void new CabooseClient(() => '').signOut().catch(() => {})
    writeSessionToken('')
    setSession(null)
  }, [session])

  let page: React.ReactNode
  if (route.page === 'setup') page = <Setup onDone={() => { signedIn({ kind: 'account' }); navigate('/', { replace: true }) }} />
  else if (route.page === 'invite') page = <AcceptInvite onDone={() => { signedIn({ kind: 'account' }); navigate('/', { replace: true }) }} />
  else if (session === 'checking') page = <main className="flex min-h-screen items-center justify-center"><RollingWordmark label="Loading" /></main>
  else if (session === null) page = <SignIn onSignIn={signedIn} />
  else page = <Console session={session} onSignOut={signOut} />

  return (
    <>
      {page}
      <ConfirmRoot />
      <PromptRoot />
      <Toaster richColors />
    </>
  )
}

function Console({ session, onSignOut }: { session: Session; onSignOut: () => void }) {
  const route = useRoute()
  const client = React.useMemo(() => new CabooseClient(() => session.kind === 'token' ? session.token : ''), [session])
  const [setupOpening, setSetupOpening] = React.useState(false)
  const [setupError, setSetupError] = React.useState<string | null>(null)
  const [me, setMe] = React.useState<Me | null>(null)
  const refreshMe = React.useCallback(async () => {
    try { setMe(await client.me()) }
    catch (failure) { if (failure instanceof CabooseApiError && failure.isUnauthorized) onSignOut() }
  }, [client, onSignOut])
  React.useEffect(() => { void refreshMe() }, [refreshMe])

  const operator = me?.operator ?? false
  const computers = useComputers(client, onSignOut)
  const host = useHost(client, onSignOut, operator)
  const awake = computers.list?.computers.some(computer => computer.state !== 'parked') ?? false

  React.useEffect(() => {
    const titles: Partial<Record<typeof route.page, string>> = { host: 'Host', computers: 'Computers', people: 'People', tenants: 'Tenants' }
    if (route.page !== 'computer') document.title = titles[route.page] ? `${titles[route.page]} — Caboose` : 'Caboose'
  }, [route.page])

  // Tenants and Host are the operator's; anyone else who lands there goes to the Overview.
  React.useEffect(() => {
    if (me && !me.operator && (route.page === 'tenants' || route.page === 'host')) navigate('/', { replace: true })
  }, [me, route.page])

  if (!me) return <main className="flex min-h-screen items-center justify-center"><RollingWordmark label="Loading" /></main>

  return (
    <AppShell
      groups={navigationGroups(operator)}
      pathname={sidebarPath(route)}
      navigationMode="sidebar"
      linkRender={linkRender}
      brand={
        // The hubs are lit while any computer is up and unlit while every one is parked;
        // a lit train rolls now and then, a parked one stays still.
        <Wordmark height={30} lit={awake} motion={awake ? 'idle' : 'none'} className="text-fg" />
      }
      header={
        <AccountMenu
          name={me.user?.name ?? 'Owner token'}
          email={me.user?.email ?? 'Signed in with CABOOSE_OWNER_TOKEN'}
          roleLabel={operator ? 'Operator' : 'Administrator'}
          showTheme={false}
          onSignOut={onSignOut}
        />
      }
    >
      {me.setupRequired ? (
        <div className="px-4 pt-4 sm:px-6">
          <Alert variant="warning">
            <AlertTitle>Finish setting up ownership</AlertTitle>
            <AlertDescription>
              <p>Create your account, household and person record, and link your existing computer. Your apps, files and paired phones stay in place.</p>
              {setupError ? <p className="mt-2 text-danger">{setupError}</p> : null}
              <Button className="mt-3" disabled={setupOpening} onClick={() => {
                setSetupOpening(true); setSetupError(null)
                void client.setupLink().then(result => { window.location.assign(result.path) }, failure => {
                  setSetupError(failure instanceof Error ? failure.message : String(failure)); setSetupOpening(false)
                })
              }}>{setupOpening ? 'Opening setup…' : 'Complete setup'}</Button>
            </AlertDescription>
          </Alert>
        </div>
      ) : null}
      {route.page === 'overview' ? <Overview computers={computers} host={host} me={me} /> : null}
      {route.page === 'computers' ? <Computers client={client} computers={computers} me={me} /> : null}
      {route.page === 'computer' ? (
        // Keyed by computer, so nothing one computer's tabs loaded is shown for another.
        <Computer key={route.id} client={client} computers={computers} id={route.id} host={host} me={me} tab={route.tab} onUnauthorized={onSignOut} />
      ) : null}
      {route.page === 'people' ? <People client={client} me={me} onUnauthorized={onSignOut} /> : null}
      {route.page === 'tenants' && operator ? <Tenants client={client} onChanged={refreshMe} onUnauthorized={onSignOut} /> : null}
      {route.page === 'host' && operator ? <Host host={host} client={client} onUnauthorized={onSignOut} /> : null}
    </AppShell>
  )
}
