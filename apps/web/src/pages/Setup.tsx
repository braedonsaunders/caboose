import * as React from 'react'
import { Alert, AlertDescription, Button, Card, CardContent, CardDescription, CardHeader, CardTitle, Input, Label } from '@braedonsaunders/appkit-ui'
import { CabooseClient } from '../api.js'
import { Wordmark } from '../brand/Logo.js'
import { errorMessage } from '../components/common.js'
import { SetupPairingStep } from './SetupPairing.js'
import { useSearchParam } from '../navigation.js'

/**
 * Setting a new host up: the first account, which is the host's operator, and the first
 * tenant, which gets every computer the host already runs. The host serves this page only
 * with the one-time code it printed and wrote to its state directory.
 */
export function Setup({ onDone }: { onDone: () => void }) {
  const code = useSearchParam('code') ?? undefined
  const client = React.useMemo(() => new CabooseClient(() => ''), [])
  const [status, setStatus] = React.useState<{ claimed: boolean; codeRequired: boolean } | null>(null)
  const [form, setForm] = React.useState({ name: '', email: '', password: '', confirm: '', tenantName: 'Home' })
  const [pairing, setPairing] = React.useState(false)
  const [saving, setSaving] = React.useState(false)
  const [error, setError] = React.useState<string | null>(null)

  React.useEffect(() => { client.setupStatus().then(setStatus, failure => setError(errorMessage(failure))) }, [client])

  const update = (changes: Partial<typeof form>) => setForm(current => ({ ...current, ...changes }))
  const mismatch = form.confirm.length > 0 && form.confirm !== form.password
  const ready = form.name.trim() && form.email.trim() && form.password.length >= 8 && form.password === form.confirm && form.tenantName.trim()

  async function submit(event: React.FormEvent) {
    event.preventDefault()
    setSaving(true)
    setError(null)
    try {
      await client.setUp({ name: form.name.trim(), email: form.email.trim(), password: form.password, tenantName: form.tenantName.trim(), ...(code ? { code } : {}) })
      setForm(current => ({ ...current, password: '', confirm: '' }))
      window.history.replaceState(null, '', '/setup')
      setPairing(true)
    } catch (failure) {
      setError(errorMessage(failure))
    } finally {
      setSaving(false)
    }
  }

  return (
    <main className="flex min-h-screen items-center justify-center p-6">
      <Card className="w-full max-w-lg">
        <CardHeader>
          <CardTitle className="mb-3"><Wordmark height={52} motion="intro" /></CardTitle>
          <CardDescription>
            {pairing ? 'Your account is ready. Connect your phone to your computer.' : <>Set up this host. Your account runs it: you can make computers, give them to the people who use them,
            and invite other administrators.</>}
          </CardDescription>
        </CardHeader>
        <CardContent>
          {pairing ? <SetupPairingStep client={client} onDone={onDone} /> : !status ? (<Alert variant={error ? "destructive" : "info"}><AlertDescription>{error ?? "Checking setup status…"}</AlertDescription></Alert>) : status.claimed ? (
            <Alert variant="info"><AlertDescription>This host is already set up. Sign in instead.</AlertDescription></Alert>
          ) : status?.codeRequired && !code ? (
            <Alert variant="warning"><AlertDescription>Open the setup link the host printed when it started; it carries the setup code.</AlertDescription></Alert>
          ) : (
            <form className="space-y-4" onSubmit={submit}>
              <div className="grid gap-4 sm:grid-cols-2">
                <div className="space-y-2">
                  <Label htmlFor="setup-name">Your name</Label>
                  <Input id="setup-name" autoFocus autoComplete="name" value={form.name} maxLength={80} onChange={event => update({ name: event.target.value })} />
                </div>
                <div className="space-y-2">
                  <Label htmlFor="setup-email">Email</Label>
                  <Input id="setup-email" type="email" autoComplete="username" value={form.email} onChange={event => update({ email: event.target.value })} />
                </div>
                <div className="space-y-2">
                  <Label htmlFor="setup-password">Password</Label>
                  <Input id="setup-password" type="password" autoComplete="new-password" value={form.password} onChange={event => update({ password: event.target.value })} />
                  <p className="text-xs text-fg-muted">At least 8 characters.</p>
                </div>
                <div className="space-y-2">
                  <Label htmlFor="setup-confirm">Password again</Label>
                  <Input id="setup-confirm" type="password" autoComplete="new-password" value={form.confirm} aria-invalid={mismatch ? true : undefined} onChange={event => update({ confirm: event.target.value })} />
                  {mismatch ? <p className="text-xs text-danger">The passwords differ.</p> : null}
                </div>
              </div>
              <div className="space-y-2">
                <Label htmlFor="setup-tenant">Household or team</Label>
                <Input id="setup-tenant" value={form.tenantName} maxLength={80} onChange={event => update({ tenantName: event.target.value })} />
                <p className="text-xs text-fg-muted">The computers this host already runs go here. You can add more households or teams later.</p>
              </div>
              {error ? <Alert variant="destructive"><AlertDescription>{error}</AlertDescription></Alert> : null}
              <Button type="submit" className="w-full" disabled={saving || !ready}>{saving ? 'Setting up…' : 'Set up Caboose'}</Button>
            </form>
          )}
        </CardContent>
      </Card>
    </main>
  )
}
