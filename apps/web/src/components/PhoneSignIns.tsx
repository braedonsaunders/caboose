import * as React from 'react'
import {
  Alert, AlertDescription, AlertTitle, Button, Spinner,
  Table, TableBody, TableCell, TableHead, TableHeader, TableRow, confirmDialog, toast,
} from '@braedonsaunders/appkit-ui'
import { KeyRound, Plus } from 'lucide-react'
import {
  CabooseApiError, buildPairingLink, formatPairingCode, type CabooseClient, type PairingCode, type PhoneSignIn,
} from '../api.js'
import { errorMessage, useVisibleInterval } from './common.js'
import { DashboardPanel } from './console-ui.js'
import { QrCode } from './QrCode.js'
import { pairingAddresses } from '../remote-access.js'

/** Where a panel's phones sign in: one computer, or the host itself. */
export interface PhoneSignInSource {
  list: () => Promise<PhoneSignIn[]>
  pair: () => Promise<PairingCode>
  remove: (phoneId: string) => Promise<unknown>
}

/**
 * Each phone signs in with its own token. The console never shows one: it shows a single-use
 * pairing code, as a QR code and a `caboose://connect` link, that the phone trades for its
 * token. Signing a phone out closes what it has open and stops its notifications.
 */
export function PhoneSignInsPanel({ client, name, source, pairLabel, title = 'Signed-in phones', note, onUnauthorized }: {
  client: CabooseClient
  title?: string
  /** What the phones sign in to, as the copy names it. */
  name: string
  source: PhoneSignInSource
  pairLabel: string
  note?: React.ReactNode
  onUnauthorized: () => void
}) {
  const [phones, setPhones] = React.useState<PhoneSignIn[] | null>(null)
  const [error, setError] = React.useState<string | null>(null)
  const [busy, setBusy] = React.useState<string | null>(null)
  const [pairing, setPairing] = React.useState<{ code: PairingCode; known: Set<string>; addresses: string[] } | null>(null)
  const [now, setNow] = React.useState(() => Date.now())

  const refresh = React.useCallback(async () => {
    try {
      const next = await source.list()
      setPhones(next)
      setError(null)
      return next
    } catch (failure) {
      if (failure instanceof CabooseApiError && failure.isUnauthorized) onUnauthorized()
      else setError(errorMessage(failure))
      return null
    }
  }, [source, onUnauthorized])
  React.useEffect(() => { void refresh() }, [refresh])

  // While a code is out, watch for the phone that uses it and count down to its expiry.
  const expired = pairing ? Date.parse(pairing.code.expiresAt) <= now : false
  useVisibleInterval(() => {
    setNow(Date.now())
    void refresh().then(next => {
      const joined = next?.find(phone => pairing && !pairing.known.has(phone.id))
      if (joined) {
        toast.success(`${joined.name} is signed in to ${name}.`)
        setPairing(null)
      }
    })
  }, 2_000, pairing !== null && !expired)

  async function start() {
    setBusy('pair')
    try {
      const known = new Set((phones ?? []).map(phone => phone.id))
      // Every address the phone may reach the host at goes in the link; an older host cannot say.
      const [code, reach] = await Promise.all([source.pair(), client.reach().catch(() => null)])
      setPairing({ code, known, addresses: pairingAddresses(reach, window.location.origin) })
      setNow(Date.now())
    } catch (failure) {
      if (failure instanceof CabooseApiError && failure.isUnauthorized) return onUnauthorized()
      toast.error(errorMessage(failure))
    } finally {
      setBusy(null)
    }
  }

  async function signOut(phone: PhoneSignIn) {
    const confirmed = await confirmDialog({
      title: `Sign ${phone.name} out?`,
      message: `It is disconnected from ${name} now and gets no more of its notifications. Signing it in again needs a new code.`,
      confirmLabel: 'Sign out',
      tone: 'danger',
    })
    if (!confirmed) return
    setBusy(phone.id)
    try {
      await source.remove(phone.id)
      toast.success(`${phone.name} was signed out.`)
    } catch (failure) {
      if (failure instanceof CabooseApiError && failure.isUnauthorized) return onUnauthorized()
      toast.error(errorMessage(failure))
    } finally {
      setBusy(null)
      await refresh()
    }
  }

  const unreachable = pairing !== null && pairing.addresses.length === 0
  const link = pairing && !unreachable ? buildPairingLink(pairing.addresses, pairing.code.code) : ''
  const remaining = pairing ? Math.max(0, Math.ceil((Date.parse(pairing.code.expiresAt) - now) / 60_000)) : 0

  return (
    <DashboardPanel
      title={title}
      icon={<KeyRound className="size-4" aria-hidden />}
      actions={pairing ? null : <Button size="sm" onClick={() => void start()} disabled={busy !== null}><Plus className="size-4" aria-hidden />{pairLabel}</Button>}
    >
      <div className="space-y-4">
        {pairing ? (
          <div className="flex flex-col gap-4 rounded-md border border-border p-4 sm:flex-row sm:items-center">
            {expired || unreachable ? null : <QrCode value={link} size={176} label={`Pairing code for ${name}`} />}
            <div className="min-w-0 flex-1 space-y-3 text-sm">
              {unreachable && !expired ? (
                <Alert variant="warning">
                  <AlertTitle>No phone can reach this host yet</AlertTitle>
                  <AlertDescription>
                    It listens only on this machine. Make it reachable under Host › Remote access, then make a new code.
                  </AlertDescription>
                </Alert>
              ) : expired ? (
                <>
                  <p className="font-medium">This code has expired.</p>
                  <p className="text-fg-muted">Codes last ten minutes. Make another to sign a phone in.</p>
                </>
              ) : (
                <>
                  <p className="font-medium">Scan this with the iPhone's camera, or open the link on it.</p>
                  <p className="text-fg-muted">
                    Caboose signs that phone in to {name} with its own sign-in. The code works once and for {remaining} more
                    {remaining === 1 ? ' minute' : ' minutes'}.
                  </p>
                  <p className="font-mono text-lg tracking-widest">{formatPairingCode(pairing.code.code)}</p>
                </>
              )}
              <div className="flex flex-wrap gap-2">
                {expired || unreachable ? (
                  <Button size="sm" onClick={() => void start()} disabled={busy !== null}>New code</Button>
                ) : (
                  <Button
                    size="sm"
                    variant="outline"
                    onClick={() => {
                      navigator.clipboard.writeText(link).then(
                        () => toast.success('Sign-in link copied.'),
                        () => toast.error('The browser did not allow copying.'))
                    }}
                  >
                    Copy link
                  </Button>
                )}
                <Button size="sm" variant="ghost" onClick={() => setPairing(null)}>{expired ? 'Close' : 'Cancel'}</Button>
              </div>
            </div>
          </div>
        ) : null}

        {error ? (
          <Alert variant="destructive"><AlertDescription>{error}</AlertDescription></Alert>
        ) : phones === null ? (
          <div className="flex items-center gap-2 text-sm text-fg-muted"><Spinner size={16} />Loading…</div>
        ) : phones.length === 0 ? (
          <p className="text-sm text-fg-muted">No phone has its own sign-in for {name} yet.</p>
        ) : (
          <Table containerClassName="border-0 shadow-none">
            <TableHeader>
              <TableRow noAnimate>
                <TableHead>Phone</TableHead>
                <TableHead className="hidden sm:table-cell">Signed in</TableHead>
                <TableHead>Last used</TableHead>
                <TableHead className="w-px"><span className="sr-only">Actions</span></TableHead>
              </TableRow>
            </TableHeader>
            <TableBody>
              {phones.map(phone => (
                <TableRow key={phone.id}>
                  <TableCell className="font-medium">{phone.name}</TableCell>
                  <TableCell className="hidden text-sm text-fg-muted sm:table-cell">{new Date(phone.createdAt).toLocaleDateString()}</TableCell>
                  <TableCell className="text-sm text-fg-muted">{phone.lastUsedAt ? new Date(phone.lastUsedAt).toLocaleString() : 'Not yet'}</TableCell>
                  <TableCell>
                    <Button size="sm" variant="ghost" disabled={busy !== null} onClick={() => void signOut(phone)}>
                      {busy === phone.id ? 'Signing out…' : 'Sign out'}
                    </Button>
                  </TableCell>
                </TableRow>
              ))}
            </TableBody>
          </Table>
        )}
        {note ? <p className="text-xs text-fg-muted">{note}</p> : null}
      </div>
    </DashboardPanel>
  )
}
