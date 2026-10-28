import * as React from 'react'
import { DashboardMetricCard, DashboardPanel } from '@braedonsaunders/appkit-dashboard/primitives'
import {
  Alert, AlertDescription, AlertTitle, Badge, PageContainer, PageHeader, Spinner,
  Table, TableBody, TableCell, TableHead, TableHeader, TableRow,
} from '@braedonsaunders/appkit-ui'
import { Activity, Bell, Cpu, HardDrive, MemoryStick, Server, SlidersHorizontal } from 'lucide-react'
import { formatMemoryMb } from '../api.js'
import { formatBytes } from '../files.js'
import { gpuLabel, healthFacts, runtimeLabel } from '../host.js'
import type { HostHandle } from '../useHost.js'

/** Only the first value of a persisted setting: the computer's Settings override them once saved. */
const INITIAL_ONLY = new Set(['CABOOSE_MEMORY_MB', 'CABOOSE_VCPUS', 'CABOOSE_IDLE_MS'])

/** The host itself: what it runs on, how it was started and how it is doing. Read-only. */
export function Host({ host }: { host: HostHandle }) {
  const { info: hostInfo, infoError: hostError, health, healthError } = host
  const machine = health?.machine

  return (
    <PageContainer>
      <div className="space-y-6">
        <PageHeader
          title="Host"
          description="The machine this console talks to: what it runs, how it was started and how it is doing. Everything here is read-only."
        />

        {hostError ? (
          <Alert variant={hostError.status === 404 ? 'warning' : 'destructive'}>
            <AlertTitle>{hostError.status === 404 ? 'This host does not describe itself' : 'Host details could not be read'}</AlertTitle>
            <AlertDescription>{hostError.status === 404 ? 'Update caboose-host to see its version and configuration here.' : hostError.message}</AlertDescription>
          </Alert>
        ) : null}

        <div className="grid gap-4 sm:grid-cols-3">
          <DashboardMetricCard label="caboose-host" value={hostInfo ? hostInfo.version : '—'} detail={hostInfo ? `Node ${hostInfo.node.replace(/^v/, '')}` : undefined} icon={<Server className="size-4" aria-hidden />} />
          <DashboardMetricCard label="Runtime" value={hostInfo ? runtimeLabel(hostInfo.runtime) : '—'} detail={hostInfo ? (hostInfo.runtime === 'container' ? 'Docker, frozen when parked' : 'Cloud Hypervisor, parked with memory') : undefined} icon={<HardDrive className="size-4" aria-hidden />} />
          <DashboardMetricCard label="GPU" value={hostInfo ? gpuLabel(hostInfo.gpu) : '—'} icon={<Cpu className="size-4" aria-hidden />} />
        </div>

        <div className="grid gap-6 xl:grid-cols-2">
          <DashboardPanel title="Machine" icon={<MemoryStick className="size-4" aria-hidden />}>
            <dl className="grid grid-cols-[minmax(8rem,auto)_1fr] gap-x-4 gap-y-2 text-sm">
              <dt className="text-fg-muted">Memory</dt>
              <dd>{machine ? `${formatMemoryMb(machine.memoryMb)}, ${formatMemoryMb(machine.availableMemoryMb)} available` : '—'}</dd>
              <dt className="text-fg-muted">CPUs</dt>
              <dd>{machine ? machine.cpus : '—'}</dd>
              <dt className="text-fg-muted">Disk</dt>
              <dd>{machine?.disk ? `${formatBytes(machine.disk.freeBytes)} free of ${formatBytes(machine.disk.totalBytes)}` : '—'}</dd>
              <dt className="text-fg-muted">Image</dt>
              <dd className="break-all">{hostInfo?.image ?? '—'}</dd>
            </dl>
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

        {hostInfo ? (
          <DashboardPanel title="Notifications" icon={<Bell className="size-4" aria-hidden />}>
            <dl className="grid grid-cols-[minmax(8rem,auto)_1fr] gap-x-4 gap-y-2 text-sm">
              <dt className="text-fg-muted">Push notifications</dt>
              <dd>{hostInfo.push ? 'Configured' : 'Not configured: set the CABOOSE_APNS_* variables and restart the host'}</dd>
              <dt className="text-fg-muted">Live Activities</dt>
              <dd>{hostInfo.liveActivities ? 'Configured' : 'Not configured'}</dd>
            </dl>
          </DashboardPanel>
        ) : null}

        {hostInfo ? (
          <DashboardPanel title="Configuration" icon={<SlidersHorizontal className="size-4" aria-hidden />}>
            <p className="mb-3 text-sm text-fg-muted">
              The host reads these when it starts. To change one, set it in the host's environment (<code>deploy/.env</code> for
              Docker Compose, or the service's environment file) and restart caboose-host; it parks the computer before it stops.
              A computer's name, memory, vCPUs and auto-park are edited in its Settings instead.
            </p>
            <Table containerClassName="border-0 shadow-none">
              <TableHeader>
                <TableRow noAnimate>
                  <TableHead>Variable</TableHead>
                  <TableHead>Value</TableHead>
                </TableRow>
              </TableHeader>
              <TableBody>
                {hostInfo.settings.map(setting => (
                  <TableRow key={setting.name}>
                    <TableCell><code className="text-xs">{setting.name}</code></TableCell>
                    <TableCell>
                      <span className="break-all font-mono text-xs">{setting.value}</span>
                      {setting.default ? <Badge variant="outline" className="ml-2">default</Badge> : null}
                      {INITIAL_ONLY.has(setting.name) ? <span className="ml-2 text-xs text-fg-muted">initial value; the computer's Settings override it</span> : null}
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
