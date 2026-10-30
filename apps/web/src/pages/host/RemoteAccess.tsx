import { DashboardPanel } from '../../components/console-ui.js'
import * as React from 'react'

import { Alert, AlertDescription, AlertTitle, Badge, Button, Spinner, Switch, toast } from '@braedonsaunders/appkit-ui'
import { Copy, Globe } from 'lucide-react'
import { CabooseApiError, type CabooseClient, type Reach } from '../../api.js'
import { errorMessage } from '../../components/common.js'
import { addressLabel, awayFromHome, tailscaleGuidance, type Guidance } from '../../remote-access.js'

function GuidanceAlert({ guidance }: { guidance: Guidance }) {
  return (
    <Alert variant={guidance.tone}>
      <AlertTitle>{guidance.title}</AlertTitle>
      <AlertDescription>
        {guidance.detail}
        {guidance.link ? <> <a className="underline" href={guidance.link.href} target="_blank" rel="noreferrer">{guidance.link.label}</a></> : null}
      </AlertDescription>
    </Alert>
  )
}

/**
 * Where phones can reach this host: its addresses, its name on the local network, and one
 * switch for Tailscale's HTTPS. Pairing links carry every address listed here.
 */
export function RemoteAccess({ client, onUnauthorized }: { client: CabooseClient; onUnauthorized: () => void }) {
  const [reach, setReach] = React.useState<Reach | null>(null)
  const [error, setError] = React.useState<{ message: string; outdated: boolean } | null>(null)
  const [busy, setBusy] = React.useState(false)

  React.useEffect(() => {
    let live = true
    client.reach().then(
      next => { if (live) { setReach(next); setError(null) } },
      failure => {
        if (!live) return
        if (failure instanceof CabooseApiError && failure.isUnauthorized) onUnauthorized()
        else setError({ message: errorMessage(failure), outdated: failure instanceof CabooseApiError && failure.status === 404 })
      })
    return () => { live = false }
  }, [client, onUnauthorized])

  async function setTailscale(enabled: boolean) {
    setBusy(true)
    try {
      setReach(await client.setTailscale(enabled))
      toast.success(enabled ? 'Caboose is reachable over Tailscale.' : 'Tailscale no longer serves Caboose.')
    } catch (failure) {
      if (failure instanceof CabooseApiError && failure.isUnauthorized) return onUnauthorized()
      toast.error(errorMessage(failure))
    } finally {
      setBusy(false)
    }
  }

  const tailscale = reach?.tailscale
  const canSwitch = !!tailscale?.installed && tailscale.loggedIn && (tailscale.serving || !tailscale.error)

  return (
    <DashboardPanel title="Remote access" icon={<Globe className="size-4" aria-hidden />}>
      {error ? (
        <Alert variant={error.outdated ? 'warning' : 'destructive'}>
          <AlertDescription>{error.outdated ? 'Update caboose-host to see and change where phones can reach it.' : error.message}</AlertDescription>
        </Alert>
      ) : !reach ? (
        <div className="flex items-center gap-2 text-sm text-fg-muted"><Spinner size={16} />Checking…</div>
      ) : (
        <div className="space-y-5">
          <GuidanceAlert guidance={awayFromHome(reach)} />

          {reach.addresses.length ? (
            <ul className="space-y-2 text-sm">
              {reach.addresses.map(address => (
                <li key={address.url} className="flex items-center gap-3">
                  <Badge variant="outline" className="shrink-0">{addressLabel(address.kind)}</Badge>
                  <code className="min-w-0 flex-1 break-all text-xs">{address.url}</code>
                  <Button
                    size="sm" variant="ghost" aria-label={`Copy ${address.url}`}
                    onClick={() => {
                      navigator.clipboard.writeText(address.url).then(
                        () => toast.success('Address copied.'),
                        () => toast.error('The browser did not allow copying.'))
                    }}
                  >
                    <Copy className="size-4" aria-hidden />
                  </Button>
                </li>
              ))}
            </ul>
          ) : null}

          <p className="text-sm text-fg-muted">
            {reach.mdns.enabled
              ? <>On the local network, the Caboose app finds this host as <span className="font-medium text-fg">{reach.mdns.name}</span>.</>
              : 'This host is not announced on the local network: it listens only on this machine, or CABOOSE_MDNS is off.'}
          </p>

          <div className="space-y-3 border-t border-border pt-4">
            <label className="flex items-center justify-between gap-4 text-sm">
              <span>
                <span className="font-medium">Tailscale</span>
                <span className="block text-fg-muted">HTTPS for every device on your tailnet, with no port forwarding</span>
              </span>
              <Switch
                checked={!!tailscale?.serving}
                disabled={busy || !canSwitch}
                onChange={event => void setTailscale(event.target.checked)}
                aria-label="Serve Caboose over Tailscale"
              />
            </label>
            {tailscale ? <GuidanceAlert guidance={tailscaleGuidance(tailscale)} /> : null}
          </div>
        </div>
      )}
    </DashboardPanel>
  )
}
