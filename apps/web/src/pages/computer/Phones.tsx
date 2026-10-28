import * as React from 'react'
import { DashboardPanel } from '@braedonsaunders/appkit-dashboard/primitives'
import {
  Alert, AlertDescription, AlertTitle, Badge, Button, EmptyState, Spinner,
  Table, TableBody, TableCell, TableHead, TableHeader, TableRow, confirmDialog, toast,
} from '@braedonsaunders/appkit-ui'
import { BellOff, KeyRound, Plus, Smartphone } from 'lucide-react'
import {
  CabooseApiError, OWNER_COMPUTER, buildPairingLink, formatPairingCode, type CabooseClient, type PairingCode, type PhoneSignIn, type PushDevice, type PushKind,
} from '../../api.js'
import { TabIntro, errorMessage, useVisibleInterval } from '../../components/common.js'
import { QrCode } from '../../components/QrCode.js'
import { pairingAddresses } from '../../remote-access.js'
import type { ComputerHandle } from '../../useComputer.js'

const KINDS: Array<{ kind: PushKind; label: string; description: string }> = [
  { kind: 'approval', label: 'Approvals', description: 'An agent asks before acting' },
  { kind: 'task', label: 'Tasks', description: 'An agent task finishes or fails' },
  { kind: 'desktop', label: 'Desktop', description: 'Linux apps post a notification' },
]

export function Phones({ client, computer, onUnauthorized }: { client: CabooseClient; computer: ComputerHandle; onUnauthorized: () => void }) {
  const configured = computer.status?.capabilities.push
  const [devices, setDevices] = React.useState<PushDevice[] | null>(null)
  const [error, setError] = React.useState<string | null>(null)
  const [removing, setRemoving] = React.useState<string | null>(null)

  const refresh = React.useCallback(async () => {
    try {
      setDevices((await client.pushDevices()).devices)
      setError(null)
    } catch (failure) {
      if (failure instanceof CabooseApiError && failure.isUnauthorized) onUnauthorized()
      else setError(errorMessage(failure))
    }
  }, [client, onUnauthorized])

  React.useEffect(() => { if (configured) void refresh() }, [configured, refresh])

  async function remove(device: PushDevice) {
    const confirmed = await confirmDialog({
      title: 'Stop notifications to this phone?',
      message: `The phone ${device.id} is unregistered and gets no more alerts from this computer. Turning notifications on again in Caboose on that phone registers it again.`,
      confirmLabel: 'Remove',
      tone: 'danger',
    })
    if (!confirmed) return
    setRemoving(device.id)
    try {
      await client.removePushDevice(device.id)
      toast.success('The phone was removed.')
    } catch (failure) {
      if (failure instanceof CabooseApiError && failure.isUnauthorized) return onUnauthorized()
      toast.error(errorMessage(failure))
    } finally {
      setRemoving(null)
      await refresh()
    }
  }

  return (
    <div className="space-y-6">
      <TabIntro description="Sign a phone in to this computer, and see which phones get its notifications when Caboose is not open on them." />

      <SignInsPanel client={client} name={computer.status?.settings.name ?? 'this computer'} onUnauthorized={onUnauthorized} />

      {configured === false ? (
        <EmptyState
          icon={<BellOff className="size-6" aria-hidden />}
          title="Push notifications are not set up on this host"
          description="Start the host with an Apple Push Notification service key: set CABOOSE_APNS_KEY_PATH, CABOOSE_APNS_KEY_ID, CABOOSE_APNS_TEAM_ID and CABOOSE_APNS_TOPIC, then restart it. The Host page shows how the host was started."
        />
      ) : null}

      {configured === undefined && computer.status ? (
        <Alert variant="warning">
          <AlertTitle>This host predates push notifications</AlertTitle>
          <AlertDescription>Update caboose-host to manage phones from here.</AlertDescription>
        </Alert>
      ) : null}

      {configured ? (
        <DashboardPanel title="Notifications" icon={<Smartphone className="size-4" aria-hidden />}>
          {error ? (
            <Alert variant="destructive"><AlertDescription>{error}</AlertDescription></Alert>
          ) : devices === null ? (
            <div className="flex items-center gap-2 text-sm text-fg-muted"><Spinner size={16} />Loading…</div>
          ) : devices.length === 0 ? (
            <EmptyState
              icon={<Smartphone className="size-6" aria-hidden />}
              title="No phones get notifications"
              description="On an iPhone signed in to this host, open Caboose › Computer settings and turn on notifications."
            />
          ) : (
            <>
              <Table containerClassName="border-0 shadow-none">
                <TableHeader>
                  <TableRow noAnimate>
                    <TableHead>Phone</TableHead>
                    <TableHead>Notifies about</TableHead>
                    <TableHead className="hidden sm:table-cell">APNs</TableHead>
                    <TableHead className="w-px"><span className="sr-only">Actions</span></TableHead>
                  </TableRow>
                </TableHeader>
                <TableBody>
                  {devices.map(device => (
                    <TableRow key={device.id}>
                      <TableCell><code className="text-xs" title="The first 16 hex digits of the SHA-256 of the phone's push token">{device.id}</code></TableCell>
                      <TableCell>
                        <div className="flex flex-wrap gap-1">
                          {KINDS.map(({ kind, label, description }) => (
                            <Badge key={kind} variant={device.kinds.includes(kind) ? 'success' : 'outline'} title={description}
                              className={device.kinds.includes(kind) ? undefined : 'text-fg-muted line-through'}>
                              {label}
                            </Badge>
                          ))}
                        </div>
                      </TableCell>
                      <TableCell className="hidden text-sm text-fg-muted sm:table-cell">
                        {device.environment === 'sandbox' ? 'Development' : 'Production'}
                      </TableCell>
                      <TableCell>
                        <Button size="sm" variant="ghost" disabled={removing !== null} onClick={() => void remove(device)}>
                          {removing === device.id ? 'Removing…' : 'Remove'}
                        </Button>
                      </TableCell>
                    </TableRow>
                  ))}
                </TableBody>
              </Table>
              <p className="mt-3 text-xs text-fg-muted">
                Phones are shown by a fingerprint of their push token; the host never sends the token itself. A phone that
                deletes Caboose is removed the next time Apple reports it unregistered.
              </p>
            </>
          )}
        </DashboardPanel>
      ) : null}
    </div>
  )
}

/**
 * Each phone signs in to this computer with its own token. The console never shows one: it
 * shows a single-use pairing code, as a QR code and a `caboose://connect` link, that the phone
 * trades for its token. Signing a phone out closes what it has open and stops its notifications.
 */
function SignInsPanel({ client, name, onUnauthorized }: { client: CabooseClient; name: string; onUnauthorized: () => void }) {
  const id = client.computerId ?? OWNER_COMPUTER
  const [phones, setPhones] = React.useState<PhoneSignIn[] | null>(null)
  const [error, setError] = React.useState<string | null>(null)
  const [busy, setBusy] = React.useState<string | null>(null)
  const [pairing, setPairing] = React.useState<{ code: PairingCode; known: Set<string>; addresses: string[] } | null>(null)
  const [now, setNow] = React.useState(() => Date.now())

  const refresh = React.useCallback(async () => {
    try {
      const next = (await client.phones(id)).phones
      setPhones(next)
      setError(null)
      return next
    } catch (failure) {
      if (failure instanceof CabooseApiError && failure.isUnauthorized) onUnauthorized()
      else setError(errorMessage(failure))
      return null
    }
  }, [client, id, onUnauthorized])
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
      const [code, reach] = await Promise.all([client.startPairing(id), client.reach().catch(() => null)])
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
      await client.removePhone(id, phone.id)
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
      title="Signed-in phones"
      icon={<KeyRound className="size-4" aria-hidden />}
      actions={pairing ? null : <Button size="sm" onClick={() => void start()} disabled={busy !== null}><Plus className="size-4" aria-hidden />Sign in a phone</Button>}
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
        {id === OWNER_COMPUTER ? (
          <p className="text-xs text-fg-muted">
            Phones signed in with the host's owner token are not listed here; changing <code>CABOOSE_OWNER_TOKEN</code> signs them out.
          </p>
        ) : null}
      </div>
    </DashboardPanel>
  )
}
