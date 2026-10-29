import { PageHeader, DashboardMetricCard, DashboardPanel, ResourceMeter } from '../components/console-ui.js'

import { Alert, AlertDescription, AlertTitle, Button, PageContainer } from '@braedonsaunders/appkit-ui'
import { Cpu, HardDrive, MemoryStick, Monitor } from 'lucide-react'
import { formatMemoryMb, type Me } from '../api.js'
import { ComputersTable } from '../components/ComputersTable.js'
import { capacityValue } from '../capacity.js'
import { fleetTotals, healthProblems, sharePercent, upgradeLabel } from '../host.js'
import { navigate } from '../navigation.js'
import type { ComputersHandle } from '../useComputer.js'
import type { HostHandle } from '../useHost.js'
import { RollingWordmark } from '../brand/Logo.js'

/** The host at a glance: what its computers are given of the machine, and anything that needs attention. */
export function Overview({ computers, host, me }: { computers: ComputersHandle; host: HostHandle; me: Me }) {
  const { list, error } = computers
  const { info, health } = host

  if (!list) {
    return (
      <PageContainer>
        {error ? (
          <Alert variant="destructive">
            <AlertTitle>The host could not be reached</AlertTitle>
            <AlertDescription>{error}</AlertDescription>
          </Alert>
        ) : <RollingWordmark label="Loading the host" />}
      </PageContainer>
    )
  }

  // Only the operator sees the machine; an administrator sees their tenants against their quotas.
  const machine = me.operator ? health?.machine : undefined
  const problems = me.operator && health ? healthProblems(health) : []
  const totals = fleetTotals(list.computers)
  const parked = list.computers.filter(computer => computer.state === 'parked' || computer.state === 'frozen').length
  const attention = list.computers.filter(computer => computer.lastError || computer.state === 'error' || computer.upgrade?.state === 'failed').length
  const quota = !me.operator && me.tenants.length === 1 ? me.tenants[0]!.quotas : null

  return (
    <PageContainer>
      <div className="space-y-4">
        <PageHeader
          title="Overview"
          actions={<><Button size="sm" variant="outline" onClick={() => navigate('/people')}>People & access</Button><Button size="sm" variant="outline" onClick={() => navigate('/usage')}>Resource usage</Button>{me.operator ? <Button size="sm" variant="outline" onClick={() => navigate('/host')}>Host</Button> : null}</>}
          description={!me.operator
            ? `The computers of ${me.tenants.map(tenant => tenant.name).join(', ') || 'your households and teams'}.`
            : info ? `caboose-host ${info.version}, running computers as ${info.runtime === 'container' ? 'containers' : 'microVMs'}.` : 'This host and the computers it runs.'}
        />

        {error ? (
          <Alert variant="warning">
            <AlertTitle>Showing the last known status</AlertTitle>
            <AlertDescription>{error}</AlertDescription>
          </Alert>
        ) : null}
        {me.operator && host.healthError ? <Alert variant="warning"><AlertTitle>Host measurements could not be refreshed</AlertTitle><AlertDescription>{host.healthError} Previously loaded measurements may be out of date.</AlertDescription></Alert> : null}
        {problems.map(problem => (
          <Alert key={problem} variant="destructive">
            <AlertTitle>The host needs attention</AlertTitle>
            <AlertDescription className="break-words">{problem}</AlertDescription>
          </Alert>
        ))}
        {attention > 0 ? <details className="rounded-lg border border-warning/30 bg-warning/5 px-4 py-3 text-sm"><summary className="cursor-pointer font-medium text-warning">{attention} {attention === 1 ? 'computer needs' : 'computers need'} attention <span className="font-normal">— review issues</span></summary><div className="mt-3 space-y-3">{list.computers.filter(computer => computer.lastError || computer.state === 'error' || computer.upgrade?.state === 'failed').map(computer => <div key={computer.id}><a className="font-medium underline underline-offset-4" href={`/computers/${computer.id}`}>{computer.settings.name}</a>{computer.lastError ? <p className="mt-1 break-words text-fg-muted">{computer.lastError}</p> : null}{computer.upgrade?.state === 'failed' ? <p className="mt-1 break-words text-fg-muted">{upgradeLabel(computer.upgrade)}{computer.upgrade.message ? `: ${computer.upgrade.message}` : ''}</p> : null}</div>)}</div></details> : null}

        <div className={`grid grid-cols-2 gap-3 ${me.operator ? 'xl:grid-cols-4' : 'xl:grid-cols-3'}`}>
          <DashboardMetricCard
            label="Computers"
            value={list.computers.length}
            detail={`${totals.running} running · ${parked} parked / sleeping`}
            icon={<Monitor className="size-4" aria-hidden />}
          />
          <DashboardMetricCard
            label="Assigned memory"
            value={formatMemoryMb(totals.memoryMb)}
            detail={machine ? `${sharePercent(totals.memoryMb, machine.memoryMb)}% of ${formatMemoryMb(machine.memoryMb)}` : quota?.memoryMb ? `of a ${formatMemoryMb(quota.memoryMb)} quota` : undefined}
            tone={machine && totals.memoryMb > machine.memoryMb ? 'warning' : undefined}
            icon={<MemoryStick className="size-4" aria-hidden />}
          />
          <DashboardMetricCard
            label="Assigned vCPUs"
            value={totals.vcpus}
            detail={machine ? `of ${machine.cpus} CPUs on this machine` : quota?.vcpus ? `of a ${quota.vcpus} vCPU quota` : undefined}
            icon={<Cpu className="size-4" aria-hidden />}
          />
          {me.operator ? <DashboardMetricCard
            label="Disk free"
            value={machine?.disk ? capacityValue({ value: machine.disk.freeBytes }, 'bytes') : '—'}
            detail={machine?.disk ? `of ${capacityValue({ value: machine.disk.totalBytes }, 'bytes')}` : undefined}
            icon={<HardDrive className="size-4" aria-hidden />}
          /> : null}
        </div>

        <div className="rounded-xl border border-border bg-surface px-4 py-3">
          <div className="grid gap-4 md:grid-cols-2 md:gap-8">
            <ResourceMeter label="Memory allocation" value={totals.memoryMb} total={machine?.memoryMb ?? quota?.memoryMb} detail={<>{formatMemoryMb(totals.memoryMb)}{machine ? ` / ${formatMemoryMb(machine.memoryMb)} host` : quota?.memoryMb ? ` / ${formatMemoryMb(quota.memoryMb)} quota` : ' assigned'}</>} />
            <ResourceMeter label="Virtual processors" value={totals.vcpus} total={machine?.cpus ?? quota?.vcpus} detail={<>{totals.vcpus}{machine ? ` / ${machine.cpus} host CPUs` : quota?.vcpus ? ` / ${quota.vcpus} quota` : ' assigned'}</>} />
          </div>
          <p className="mt-3 text-xs text-fg-muted">Configured allocations, including parked computers; not measured memory or CPU use.</p>
        </div>

        <DashboardPanel
          title="Computers"
          icon={<Monitor className="size-4" aria-hidden />}
          actions={<Button size="sm" variant="outline" onClick={() => navigate('/computers')}>Manage</Button>}
        >
          <ComputersTable computers={list.computers} tenants={me.tenants} />
        </DashboardPanel>
      </div>
    </PageContainer>
  )
}
