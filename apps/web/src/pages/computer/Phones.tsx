import * as React from 'react'
import { DashboardPanel } from '@braedonsaunders/appkit-dashboard/primitives'
import {
  Alert, AlertDescription, AlertTitle, Badge, Button, EmptyState, Spinner,
  Table, TableBody, TableCell, TableHead, TableHeader, TableRow, confirmDialog, toast,
} from '@braedonsaunders/appkit-ui'
import { BellOff, Link2, Smartphone } from 'lucide-react'
import { CabooseApiError, buildIosPairingUrl, type CabooseClient, type PushDevice, type PushKind } from '../../api.js'
import { TabIntro, errorMessage } from '../../components/common.js'
import type { ComputerHandle } from '../../useComputer.js'

const KINDS: Array<{ kind: PushKind; label: string; description: string }> = [
  { kind: 'approval', label: 'Approvals', description: 'An agent asks before acting' },
  { kind: 'task', label: 'Tasks', description: 'An agent task finishes or fails' },
  { kind: 'desktop', label: 'Desktop', description: 'Linux apps post a notification' },
]

export function Phones({ client, computer, token, onUnauthorized }: { client: CabooseClient; computer: ComputerHandle; token: string; onUnauthorized: () => void }) {
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
      message: `The phone ${device.id} is unregistered and gets no more alerts from this host. Turning notifications on again in Caboose on that phone registers it again.`,
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

      <PairingPanel token={token} />

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
 * The link that signs Caboose on an iPhone in to this host. It carries the owner token, the
 * host's only credential, so it is hidden until asked for.
 */
function PairingPanel({ token }: { token: string }) {
  const [shown, setShown] = React.useState(false)
  const link = buildIosPairingUrl(window.location.origin, token)
  return (
    <DashboardPanel title="Connect a phone" icon={<Link2 className="size-4" aria-hidden />}>
      <div className="space-y-3 text-sm">
        <p className="text-fg-muted">
          Open this link on an iPhone with Caboose installed to sign it in. The link carries the host's owner token, so
          share it only with your own devices; a phone signed in this way can be signed out only by changing the token.
        </p>
        {shown ? <code className="block break-all rounded-md bg-bg-subtle p-3 text-xs">{link}</code> : null}
        <div className="flex flex-wrap gap-2">
          <Button variant="outline" size="sm" onClick={() => setShown(value => !value)}>{shown ? 'Hide link' : 'Show link'}</Button>
          <Button
            variant="outline"
            size="sm"
            onClick={() => {
              navigator.clipboard.writeText(link).then(
                () => toast.success('Sign-in link copied.'),
                () => toast.error('The browser did not allow copying.'))
            }}
          >
            Copy link
          </Button>
        </div>
      </div>
    </DashboardPanel>
  )
}
