import { Wordmark } from '../brand/Logo.js'
import * as React from 'react'
import { Alert, AlertDescription, Button, Card, CardContent, CardHeader, CardTitle, Input, Label } from '@braedonsaunders/appkit-ui'
import { securityRequest } from '../security-api.js'

export function PasswordRecovery() {
  const [token] = React.useState(() => new URLSearchParams(window.location.search).get('token'))
  const [email, setEmail] = React.useState('')
  const [password, setPassword] = React.useState('')
  const [confirm, setConfirm] = React.useState('')
  const [busy, setBusy] = React.useState(false)
  const [message, setMessage] = React.useState('')
  const [error, setError] = React.useState(() => new URLSearchParams(window.location.search).has('error') ? 'This recovery link is invalid or expired. Request a new link.' : '')
  React.useEffect(() => { if (token) window.history.replaceState(null, '', window.location.pathname) }, [token])
  async function submit(event: React.FormEvent) {
    event.preventDefault(); setBusy(true); setError('')
    try {
      if (token) { await securityRequest('reset-password', { token, newPassword: password }); setMessage('Password reset. Sign in with your new password and authenticator.'); setPassword(''); setConfirm('') }
      else { await securityRequest('request-password-reset', { email }); setMessage('If an account matches that email, a recovery link has been sent.') }
    } catch (failure) { setError(failure instanceof Error ? failure.message : 'Recovery failed') }
    finally { setBusy(false) }
  }
  return <main className="flex min-h-screen items-center justify-center bg-bg-subtle p-6"><div className="w-full max-w-md space-y-8"><div className="flex justify-center"><Wordmark height={36} /></div><Card className="w-full"><CardHeader><CardTitle>{token ? 'Reset password' : 'Recover your account'}</CardTitle><p className="mt-2 text-sm leading-relaxed text-fg-muted">{token ? 'Choose a new password for your administrator account.' : 'Enter your administrator email to request a password reset link.'}</p></CardHeader><CardContent>
    <form className="space-y-4" onSubmit={submit}>
      {token ? <><Label htmlFor="reset-password">New password</Label><Input id="reset-password" type="password" autoComplete="new-password" value={password} onChange={e => setPassword(e.target.value)} /><Label htmlFor="reset-confirm">Confirm password</Label><Input id="reset-confirm" type="password" autoComplete="new-password" value={confirm} onChange={e => setConfirm(e.target.value)} /></> : <><Label htmlFor="recovery-email">Email</Label><Input id="recovery-email" type="email" autoComplete="email" required value={email} onChange={e => setEmail(e.target.value)} /></>}
      {error && <Alert variant="destructive"><AlertDescription>{error}</AlertDescription></Alert>}{message && <p role="status">{message}</p>}
      <Button className="w-full" disabled={busy || (token ? password.length < 8 || password !== confirm : !email)}>{busy ? 'Please wait…' : token ? 'Reset password' : 'Send recovery link'}</Button>
      <a className="block text-center text-sm text-primary underline-offset-4 hover:underline" href="/">Back to sign in</a>
    </form>
  </CardContent></Card></div></main>
}
