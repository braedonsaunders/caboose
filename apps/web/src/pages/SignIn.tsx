import * as React from 'react'
import { Alert, AlertDescription, Button, Card, CardContent, CardDescription, CardHeader, CardTitle, Input, Label } from '@braedonsaunders/appkit-ui'
import { CabooseApiError, CabooseClient } from '../api.js'
import { securityRequest } from '../security-api.js'
import { Wordmark } from '../brand/Logo.js'
import { errorMessage } from '../components/common.js'

/**
 * Administrators sign in with their account. The owner token still opens the console, for
 * the installers and for a host whose accounts are out of reach; it is checked against the
 * host before it is kept, only for this tab, and never put in a URL.
 */
export function SignIn({ onSignIn }: { onSignIn: (session: { kind: 'account' } | { kind: 'token'; token: string }) => void }) {
  const [challenge, setChallenge] = React.useState(false)
  const [recoveryCode, setRecoveryCode] = React.useState(false)
  const [code, setCode] = React.useState('')
  const [recoveryAvailable, setRecoveryAvailable] = React.useState(false)
  const [mode, setMode] = React.useState<'account' | 'token'>('account')
  const [email, setEmail] = React.useState('')
  const [password, setPassword] = React.useState('')
  const [token, setToken] = React.useState('')
  const [checking, setChecking] = React.useState(false)
  const [error, setError] = React.useState<string | null>(null)
  const [unclaimed, setUnclaimed] = React.useState(false)

  React.useEffect(() => {
    void securityRequest<{ recoveryAvailable: boolean }>('security-config').then(value => setRecoveryAvailable(value.recoveryAvailable)).catch(() => {})
    new CabooseClient(() => '').setupStatus().then(
      status => setUnclaimed(!status.claimed),
      () => setUnclaimed(false),
    )
  }, [])

  async function submit(event: React.FormEvent) {
    event.preventDefault()
    setChecking(true)
    setError(null)
    try {
      if (mode === 'account') {
        const client = new CabooseClient(() => '')
        if (challenge) await securityRequest(recoveryCode ? 'two-factor/verify-backup-code' : 'two-factor/verify-totp', { code, trustDevice: false })
        else {
          const result = await securityRequest<{ twoFactorRedirect?: boolean }>('sign-in/email', { email: email.trim(), password })
          setPassword('')
          if (result.twoFactorRedirect) { setChallenge(true); return }
        }
        await client.me()
        onSignIn({ kind: 'account' })
      } else {
        const candidate = token.trim()
        await new CabooseClient(() => candidate).me()
        onSignIn({ kind: 'token', token: candidate })
      }
    } catch (failure) {
      setError(failure instanceof CabooseApiError && failure.isUnauthorized
        ? mode === 'account' ? 'That email and password did not sign in.' : 'This host did not accept that token.'
        : errorMessage(failure))
    } finally {
      setChecking(false)
    }
  }

  return (
    <main className="flex min-h-screen items-center justify-center p-6">
      <Card className="w-full max-w-md">
        <CardHeader>
          <CardTitle className="mb-3">
            <Wordmark height={52} motion="intro" />
          </CardTitle>
          <CardDescription>
            Run this host's computers: who has one, how big each is, its files, apps and phones.
          </CardDescription>
        </CardHeader>
        <CardContent className="space-y-4">
          {unclaimed ? (
            <Alert variant="info">
              <AlertDescription>
                <div className="space-y-2">
                  <p>This host has not been set up yet.</p>
                  <p>Open the setup link the host printed when it started; it carries the one-time setup code.</p>
                </div>
              </AlertDescription>
            </Alert>
          ) : null}
          <form className="space-y-4" onSubmit={submit}>
            {mode === 'account' && challenge ? (<div className="space-y-2"><Label htmlFor="mfa-code">{recoveryCode ? 'Recovery code' : 'Authenticator code'}</Label><Input id="mfa-code" autoComplete="one-time-code" value={code} onChange={event => setCode(event.target.value)} /><Button type="button" variant="ghost" onClick={() => { setRecoveryCode(!recoveryCode); setCode('') }}>{recoveryCode ? 'Use authenticator' : 'Use a recovery code'}</Button></div>) : mode === 'account' ? (
              <>
                <div className="space-y-2">
                  <Label htmlFor="email">Email</Label>
                  <Input id="email" type="email" autoComplete="username" autoFocus value={email} onChange={event => setEmail(event.target.value)} />
                </div>
                <div className="space-y-2">
                  <Label htmlFor="password">Password</Label>
                  <Input id="password" type="password" autoComplete="current-password" value={password} onChange={event => setPassword(event.target.value)} />
                </div>
              </>
            ) : (
              <div className="space-y-2">
                <Label htmlFor="token">Owner token</Label>
                <Input id="token" type="password" autoComplete="off" autoFocus value={token} onChange={event => setToken(event.target.value)} />
                <p className="text-sm text-fg-muted">
                  <code>CABOOSE_OWNER_TOKEN</code>, or the <code>owner-token</code> file in the host's state directory.
                </p>
              </div>
            )}
            {error ? (
              <Alert variant="destructive">
                <AlertDescription>{error}</AlertDescription>
              </Alert>
            ) : null}
            <Button type="submit" className="w-full" disabled={checking || (mode === 'account' ? challenge ? !code : !email.trim() || !password : !token.trim())}>
              {checking ? 'Signing in…' : 'Sign in'}
            </Button>
          </form>
          {recoveryAvailable && <a className="block text-sm text-primary" href="/recover">Forgot password?</a>}
          <Button
            variant="ghost"
            size="sm"
            className="w-full"
            onClick={() => { setMode(mode === 'account' ? 'token' : 'account'); setChallenge(false); setCode(''); setError(null) }}
          >
            {mode === 'account' ? 'Use the owner token instead' : 'Sign in with an account instead'}
          </Button>
        </CardContent>
      </Card>
    </main>
  )
}
