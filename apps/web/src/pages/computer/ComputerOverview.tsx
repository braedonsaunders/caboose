import { DashboardMetricCard, DashboardPanel } from '@braedonsaunders/appkit-dashboard/primitives'
import { Badge } from '@braedonsaunders/appkit-ui'
import { Clock, Cpu, HardDrive, Smartphone } from 'lucide-react'
import { formatIdleDuration, formatMemoryMb } from '../../api.js'
import { runtimeLabel, upgradeLabel } from '../../host.js'
import type { ComputerHandle } from '../../useComputer.js'
import type { HostHandle } from '../../useHost.js'

export function ComputerOverview({ computer, host }: { computer: ComputerHandle; host: HostHandle }) {
  const status = computer.status!
  const active = status.activeResources
  const upgrade = status.upgrade
  const info = host.info

  return (
    <div className="space-y-6">
      <div className="grid gap-4 sm:grid-cols-2 xl:grid-cols-4">
        <DashboardMetricCard
          label="Running with"
          value={active ? formatMemoryMb(active.memoryMb) : '—'}
          detail={active ? `${active.vcpus} vCPUs` : 'Known after the next cold boot'}
          icon={<Cpu className="size-4" aria-hidden />}
        />
        <DashboardMetricCard
          label="Screens connected"
          value={status.clients.display}
          detail={status.clients.display ? 'Holding it awake' : 'Parks when idle'}
          icon={<Smartphone className="size-4" aria-hidden />}
        />
        <DashboardMetricCard
          label="Parks after"
          value={formatIdleDuration(status.settings.idleMs)}
          detail="with nothing connected"
          icon={<Clock className="size-4" aria-hidden />}
        />
        <DashboardMetricCard
          label="Runtime"
          value={info ? runtimeLabel(info.runtime) : '—'}
          detail={info ? (info.runtime === 'container' ? 'Frozen when parked' : 'Parked with its memory') : undefined}
          icon={<HardDrive className="size-4" aria-hidden />}
        />
      </div>

      <DashboardPanel title="Details" icon={<HardDrive className="size-4" aria-hidden />}>
        <dl className="grid grid-cols-[minmax(10rem,auto)_1fr] gap-x-4 gap-y-2 text-sm">
          <dt className="text-fg-muted">Image</dt>
          <dd className="break-all">{info?.image ?? '—'}</dd>
          <dt className="text-fg-muted">Next boot</dt>
          <dd>{formatMemoryMb(status.settings.memoryMb)} · {status.settings.vcpus} vCPUs</dd>
          <dt className="text-fg-muted">Restart</dt>
          <dd>{status.capabilities.restart ? 'Available' : 'Not offered by this runtime'}</dd>
          {upgrade ? (
            <>
              <dt className="text-fg-muted">Caboose components</dt>
              <dd>
                <Badge variant={upgrade.state === 'failed' ? 'destructive' : upgrade.state === 'succeeded' ? 'success' : 'info'}>{upgradeLabel(upgrade)}</Badge>
                {upgrade.version ? <div className="mt-1 font-mono text-xs text-fg-muted" title="Hash of the bundled guest components">{upgrade.version.slice(0, 12)}</div> : null}
                {upgrade.message ? <p className="mt-1 text-xs text-fg-muted">{upgrade.message}</p> : null}
              </dd>
            </>
          ) : null}
        </dl>
      </DashboardPanel>
    </div>
  )
}
