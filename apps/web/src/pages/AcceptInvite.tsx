import * as React from 'react'
import { Alert, AlertDescription, Button, Card, CardContent, CardDescription, CardHeader, CardTitle, Input, Label } from '@braedonsaunders/appkit-ui'
import { CabooseClient, type InviteDetails } from '../api.js'
import { SignIn } from './SignIn.js'
import { Wordmark } from '../brand/Logo.js'
import { errorMessage } from '../components/common.js'
import { useSearchParam } from '../navigation.js'

/**
 * Accepting an invitation to administer a tenant: a new administrator chooses a name and
 * password; someone with an account completes sign-in including MFA first.
 */
export function AcceptInvite({ onDone }: { onDone: () => void }) {
  const token = useSearchParam('token') ?? ''
  const client = React.useMemo(() => new CabooseClient(() => ''), [])
  const [signedIn, setSignedIn] = React.useState(false)
  const [invite, setInvite] = React.useState<InviteDetails | null>(null)
  const [problem, setProblem] = React.useState<string | null>(null)
  const [form, setForm] = React.useState({ name: '', password: '', confirm: '' })
  const [saving, setSaving] = React.useState(false)
  const [error, setError] = React.useState<string | null>(null)

  React.useEffect(() => {
    if (!token) { setProblem('This invitation link is incomplete.'); return }
    client.invitation(token).then(setInvite, failure => setProblem(errorMessage(failure)))
  }, [client, token])

  const update = (changes: Partial<typeof form>) => setForm(current => ({ ...current, ...changes }))
  const newAccount = invite ? !invite.accountExists : false
  const mismatch = newAccount && form.confirm.length > 0 && form.confirm !== form.password
  const ready = newAccount ? form.name.trim() && form.password.length >= 8 && form.password === form.confirm : signedIn

  async function submit(event: React.FormEvent) {
    event.preventDefault()
    setSaving(true)
    setError(null)
    try {
      await client.acceptInvitation(token, newAccount ? { name: form.name.trim(), password: form.password } : { password: form.password })
      onDone()
    } catch (failure) {
      setError(errorMessage(failure))
    } finally {
      setSaving(false)
    }
  }

  if (invite?.accountExists && !signedIn) return <SignIn onSignIn={session => { if (session.kind === 'account') setSignedIn(true) }} />

  return (
    <main className="flex min-h-screen items-center justify-center p-6">
      <Card className="w-full max-w-md">
        <CardHeader>
          <CardTitle className="mb-3"><Wordmark height={52} motion="intro" /></CardTitle>
          <CardDescription>
            {invite ? <>You're invited to administer <strong>{invite.tenantName}</strong>'s computers as {invite.email}.</> : 'An invitation to administer computers on this host.'}
          </CardDescription>
        </CardHeader>
        <CardContent>
          {problem ? (
            <Alert variant="destructive"><AlertDescription>{problem} Ask whoever invited you for a new link.</AlertDescription></Alert>
          ) : !invite ? null : (
            <form className="space-y-4" onSubmit={submit}>
              {newAccount ? (
                <>
                  <div className="space-y-2">
                    <Label htmlFor="invite-name">Your name</Label>
                    <Input id="invite-name" autoFocus autoComplete="name" maxLength={80} value={form.name} onChange={event => update({ name: event.target.value })} />
                  </div>
                  <div className="space-y-2">
                    <Label htmlFor="invite-password">Choose a password</Label>
                    <Input id="invite-password" type="password" autoComplete="new-password" value={form.password} onChange={event => update({ password: event.target.value })} />
                    <p className="text-xs text-fg-muted">At least 8 characters.</p>
                  </div>
                  <div className="space-y-2">
                    <Label htmlFor="invite-confirm">Password again</Label>
                    <Input id="invite-confirm" type="password" autoComplete="new-password" value={form.confirm} aria-invalid={mismatch ? true : undefined} onChange={event => update({ confirm: event.target.value })} />
                    {mismatch ? <p className="text-xs text-danger">The passwords differ.</p> : null}
                  </div>
                </>
              ) : (
                <p className="text-sm text-fg-muted">Accept as {invite.email}. Your completed sign-in is required.</p>
              )}
              {error ? <Alert variant="destructive"><AlertDescription>{error}</AlertDescription></Alert> : null}
              <Button type="submit" className="w-full" disabled={saving || !ready}>{saving ? 'Joining…' : 'Accept invitation'}</Button>
            </form>
          )}
        </CardContent>
      </Card>
    </main>
  )
}
