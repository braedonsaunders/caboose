import * as React from 'react'
import { DashboardMetricCard, DashboardPanel } from '@braedonsaunders/appkit-dashboard/primitives'
import {
  Alert, AlertDescription, AlertTitle, Badge, PageContainer, PageHeader, Spinner,
  Table, TableBody, TableCell, TableHead, TableHeader, TableRow,
} from '@braedonsaunders/appkit-ui'
import { Activity, Cpu, HardDrive, MonitorPlay, Server, SlidersHorizontal } from 'lucide-react'
import { CabooseApiError, type CabooseClient } from '../api.js'
import { errorMessage, useVisibleInterval } from '../components/common.js'
import { displayLabel, gpuLabel, healthFacts, runtimeLabel, upgradeLabel, type HealthStatus, type HostInfo } from '../host.js'
import { stateLabel, stateTone } from '../state.js'
import type { ComputerHandle } from '../useComputer.js'

const HEALTH_POLL_MS = 10_000
/** Only the first value of a persisted setting: Settings overrides them once saved. */
const INITIAL_ONLY = new Set(['CABOOSE_MEMORY_MB', 'CABOOSE_VCPUS', 'CABOOSE_IDLE_MS'])

export function System({ client, computer, onUnauthorized }: { client: CabooseClient; computer: ComputerHandle; onUnauthorized: () => void }) {
  const [host, setHost] = React.useState<HostInfo | null>(null)
  const [hostError, setHostError] = React.useState<{ status: number; message: string } | null>(null)
  const [health, setHealth] = React.useState<HealthStatus | null>(null)
  const [healthError, setHealthError] = React.useState<string | null>(null)

  React.useEffect(() => {
    let current = true
    client.host().then(
      value => { if (current) setHost(value) },
      failure => {
        if (!current) return
        if (failure instanceof CabooseApiError && failure.isUnauthorized) onUnauthorized()
        else setHostError({ status: failure instanceof CabooseApiError ? failure.status : 0, message: errorMessage(failure) })
      },
    )
    return () => { current = false }
  }, [client, onUnauthorized])

  const refreshHealth = React.useCallback(async () => {
    try {
      setHealth(await client.health())
      setHealthError(null)
    } catch (failure) {
      if (failure instanceof CabooseApiError && failure.isUnauthorized) onUnauthorized()
      else setHealthError(errorMessage(failure))
    }
  }, [client, onUnauthorized])
  React.useEffect(() => { void refreshHealth() }, [refreshHealth])
  useVisibleInterval(() => void refreshHealth(), HEALTH_POLL_MS)

  const status = computer.status
  const upgrade = status?.upgrade

  return (
    <PageContainer>
      <div className="space-y-6">
        <PageHeader
          title="System"
          description="The host this console talks to: what it runs, how it was started and how it is doing. Everything here is read-only."
        />

        {hostError ? (
          <Alert variant={hostError.status === 404 ? 'warning' : 'destructive'}>
            <AlertTitle>{hostError.status === 404 ? 'This host does not describe itself' : 'Host details could not be read'}</AlertTitle>
            <AlertDescription>{hostError.status === 404 ? 'Update caboose-host to see its version and configuration here.' : hostError.message}</AlertDescription>
          </Alert>
        ) : null}

        <div className="grid gap-4 sm:grid-cols-2 xl:grid-cols-4">
          <DashboardMetricCard label="caboose-host" value={host ? host.version : '—'} detail={host ? `Node ${host.node.replace(/^v/, '')}` : undefined} icon={<Server className="size-4" aria-hidden />} />
          <DashboardMetricCard label="Runtime" value={host ? runtimeLabel(host.runtime) : '—'} detail={host ? (host.runtime === 'container' ? 'Docker, frozen when parked' : 'Cloud Hypervisor, parked with memory') : undefined} icon={<HardDrive className="size-4" aria-hidden />} />
          <DashboardMetricCard label="Display" value={host ? displayLabel(host.display) : '—'} detail={host ? host.display : undefined} icon={<MonitorPlay className="size-4" aria-hidden />} />
          <DashboardMetricCard label="GPU" value={host ? gpuLabel(host.gpu) : '—'} icon={<Cpu className="size-4" aria-hidden />} />
        </div>

        <div className="grid gap-6 xl:grid-cols-2">
          <DashboardPanel title="Computer" icon={<HardDrive className="size-4" aria-hidden />}>
            <dl className="grid grid-cols-[minmax(8rem,auto)_1fr] gap-x-4 gap-y-2 text-sm">
              <dt className="text-fg-muted">State</dt>
              <dd>{status ? <Badge variant={stateTone(status.state)}>{stateLabel(status.state)}</Badge> : '—'}</dd>
              <dt className="text-fg-muted">Image</dt>
              <dd className="break-all">{host?.image ?? '—'}</dd>
              <dt className="text-fg-muted">Push notifications</dt>
              <dd>{host ? (host.push ? 'Configured' : 'Not configured') : '—'}</dd>
              <dt className="text-fg-muted">Live Activities</dt>
              <dd>{host ? (host.liveActivities ? 'Configured' : 'Not configured') : '—'}</dd>
              {upgrade ? (
                <>
                  <dt className="text-fg-muted">Components</dt>
                  <dd>
                    <Badge variant={upgrade.state === 'failed' ? 'destructive' : upgrade.state === 'succeeded' ? 'success' : 'info'}>{upgradeLabel(upgrade)}</Badge>
                    {upgrade.version ? <div className="mt-1 font-mono text-xs text-fg-muted" title="Hash of the bundled guest components">{upgrade.version.slice(0, 12)}</div> : null}
                    {upgrade.message ? <p className="mt-1 text-xs text-fg-muted">{upgrade.message}</p> : null}
                  </dd>
                </>
              ) : null}
            </dl>
            {status?.lastError ? (
              <Alert variant="destructive" className="mt-4">
                <AlertTitle>Last lifecycle error</AlertTitle>
                <AlertDescription className="font-mono text-xs break-all">{status.lastError}</AlertDescription>
              </Alert>
            ) : null}
          </DashboardPanel>

          <DashboardPanel title="Health" icon={<Activity className="size-4" aria-hidden />}>
            {healthError ? (
              <Alert variant="destructive"><AlertDescription>{healthError}</AlertDescription></Alert>
            ) : !health ? (
              <div className="flex items-center gap-2 text-sm text-fg-muted"><Spinner size={16} />Checking…</div>
            ) : (
              <dl className="grid grid-cols-[minmax(8rem,auto)_1fr] gap-x-4 gap-y-2 text-sm">
                {healthFacts(health).map(fact => (
                  <React.Fragment key={fact.label}>
                    <dt className="text-fg-muted">{fact.label}</dt>
                    <dd className={fact.problem ? 'break-words text-danger' : 'break-words'}>{fact.value}</dd>
                  </React.Fragment>
                ))}
              </dl>
            )}
          </DashboardPanel>
        </div>

        {host ? (
          <DashboardPanel title="Configuration" icon={<SlidersHorizontal className="size-4" aria-hidden />}>
            <p className="mb-3 text-sm text-fg-muted">
              The host reads these when it starts. To change one, set it in the host's environment (<code>deploy/.env</code> for
              Docker Compose, or the service's environment file) and restart caboose-host; it parks the computer before it stops.
              Name, memory, vCPUs, auto-park and the default agent are edited in Settings instead.
            </p>
            <Table containerClassName="border-0 shadow-none">
              <TableHeader>
                <TableRow noAnimate>
                  <TableHead>Variable</TableHead>
                  <TableHead>Value</TableHead>
                </TableRow>
              </TableHeader>
              <TableBody>
                {host.settings.map(setting => (
                  <TableRow key={setting.name}>
                    <TableCell><code className="text-xs">{setting.name}</code></TableCell>
                    <TableCell>
                      <span className="break-all font-mono text-xs">{setting.value}</span>
                      {setting.default ? <Badge variant="outline" className="ml-2">default</Badge> : null}
                      {INITIAL_ONLY.has(setting.name) ? <span className="ml-2 text-xs text-fg-muted">initial value; Settings overrides it</span> : null}
                    </TableCell>
                  </TableRow>
                ))}
              </TableBody>
            </Table>
          </DashboardPanel>
        ) : null}
      </div>
    </PageContainer>
  )
}
