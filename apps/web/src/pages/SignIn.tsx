import * as React from 'react'
import { Alert, AlertDescription, Button, Card, CardContent, CardDescription, CardHeader, CardTitle, Input, Label } from '@braedonsaunders/appkit-ui'
import { TrainFront } from 'lucide-react'
import { CabooseApiError, CabooseClient } from '../api.js'

/**
 * The owner token is checked against the host before it is kept, and only for this
 * browser tab (session storage). It is never put in a URL.
 */
export function SignIn({ onSignIn }: { onSignIn: (token: string) => void }) {
  const [token, setToken] = React.useState('')
  const [checking, setChecking] = React.useState(false)
  const [error, setError] = React.useState<string | null>(null)

  async function submit(event: React.FormEvent) {
    event.preventDefault()
    const candidate = token.trim()
    if (!candidate) return
    setChecking(true)
    setError(null)
    try {
      await new CabooseClient(() => candidate).computer()
      onSignIn(candidate)
    } catch (failure) {
      setError(failure instanceof CabooseApiError && failure.isUnauthorized
        ? 'This host did not accept that token.'
        : failure instanceof Error ? failure.message : String(failure))
    } finally {
      setChecking(false)
    }
  }

  return (
    <main className="flex min-h-screen items-center justify-center p-6">
      <Card className="w-full max-w-md">
        <CardHeader>
          <TrainFront className="mb-2 size-8" aria-hidden />
          <CardTitle>Caboose</CardTitle>
          <CardDescription>
            Manage the computer this host runs: its settings, parking, restarts and agents.
          </CardDescription>
        </CardHeader>
        <CardContent>
          <form className="space-y-4" onSubmit={submit}>
            <div className="space-y-2">
              <Label htmlFor="token">Owner token</Label>
              <Input
                id="token"
                type="password"
                autoComplete="current-password"
                autoFocus
                value={token}
                onChange={event => setToken(event.target.value)}
                aria-invalid={error ? true : undefined}
              />
              <p className="text-sm text-muted-foreground">
                The <code>CABOOSE_OWNER_TOKEN</code> this host was started with.
              </p>
            </div>
            {error ? (
              <Alert variant="destructive">
                <AlertDescription>{error}</AlertDescription>
              </Alert>
            ) : null}
            <Button type="submit" className="w-full" disabled={checking || !token.trim()}>
              {checking ? 'Checking…' : 'Sign in'}
            </Button>
          </form>
        </CardContent>
      </Card>
    </main>
  )
}
