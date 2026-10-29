import { PageHeader, DashboardMetricCard, DashboardPanel, ResourceMeter } from '../components/console-ui.js'

import { AnimatedNumber, Alert, AlertDescription, AlertTitle, Button, PageContainer } from '@braedonsaunders/appkit-ui'
import { ArrowUpRight, Cpu, HardDrive, MemoryStick, Monitor, Users, Server, ChartNoAxesCombined } from 'lucide-react'
import { formatMemoryMb, type Me } from '../api.js'
import { ComputersTable } from '../components/ComputersTable.js'
import { formatBytes } from '../files.js'
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
        {list.computers.flatMap(computer => [
          computer.lastError ? (
            <Alert key={`${computer.id}:error`} variant="destructive">
              <AlertTitle>{computer.settings.name}: last lifecycle error</AlertTitle>
              <AlertDescription className="font-mono text-xs break-all">{computer.lastError}</AlertDescription>
            </Alert>
          ) : null,
          computer.upgrade?.state === 'failed' ? (
            <Alert key={`${computer.id}:upgrade`} variant="warning">
              <AlertTitle>{computer.settings.name}: {upgradeLabel(computer.upgrade)}</AlertTitle>
              {computer.upgrade.message ? <AlertDescription className="break-words">{computer.upgrade.message}</AlertDescription> : null}
            </Alert>
          ) : null,
        ])}

        <div className={`grid gap-4 sm:grid-cols-2 ${me.operator ? 'xl:grid-cols-4' : 'xl:grid-cols-3'}`}>
          <DashboardMetricCard
            label="Computers"
            value={list.computers.length}
            detail={totals.running ? `${totals.running} running` : 'None running'}
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
            value={machine?.disk ? formatBytes(machine.disk.freeBytes) : '—'}
            detail={machine?.disk ? `of ${formatBytes(machine.disk.totalBytes)}` : undefined}
            icon={<HardDrive className="size-4" aria-hidden />}
          /> : null}
        </div>

        <div className="grid items-start gap-4 xl:grid-cols-[minmax(0,1.6fr)_minmax(0,1fr)]">
          <DashboardPanel title="Fleet at a glance" icon={<Monitor className="size-4" aria-hidden />}>
            <div className="grid grid-cols-3 divide-x divide-border pb-4">
              {([[totals.running, 'Running'], [parked, 'Parked / sleeping'], [attention, 'Need attention']] as const).map(([value, label]) => <div key={label} className="px-3 first:pl-0"><p className="text-3xl font-semibold tracking-tight tabular-nums"><AnimatedNumber value={value} /></p><p className="mt-2 text-xs text-fg-muted">{label}</p></div>)}
            </div>
            <div className="space-y-4 border-t border-border pt-4">
              <ResourceMeter label="Memory allocation" value={totals.memoryMb} total={machine?.memoryMb ?? quota?.memoryMb} detail={<>{formatMemoryMb(totals.memoryMb)}{machine ? ` / ${formatMemoryMb(machine.memoryMb)} host` : quota?.memoryMb ? ` / ${formatMemoryMb(quota.memoryMb)} quota` : ' assigned'}</>} />
              <ResourceMeter label="Virtual processors" value={totals.vcpus} total={machine?.cpus ?? quota?.vcpus} detail={<>{totals.vcpus}{machine ? ` / ${machine.cpus} host CPUs` : quota?.vcpus ? ` / ${quota.vcpus} quota` : ' assigned'}</>} />
              <p className="text-xs leading-relaxed text-fg-muted">Allocations reflect configured computer sizes, including parked computers. They are not measured memory or CPU use.</p>
            </div>
          </DashboardPanel>
          <DashboardPanel title="Manage your workspace">
            {[
              { href: '/people', title: 'People & access', detail: 'Computer owners, administrators and invitations', Icon: Users },
              { href: '/usage', title: 'Resource usage', detail: 'Allocations, quotas and measured storage', Icon: ChartNoAxesCombined },
              ...(me.operator ? [{ href: '/host', title: 'Host configuration', detail: 'Runtime, health and remote access', Icon: Server }] : []),
            ].map(({ href, title, detail, Icon }) => <a key={href} href={href} className="console-link-row" onClick={event => { if (event.metaKey || event.ctrlKey || event.shiftKey || event.altKey) return; event.preventDefault(); navigate(href) }}><Icon className="size-5 shrink-0 text-fg-muted" aria-hidden /><span className="min-w-0 flex-1"><span className="block text-sm font-medium">{title}</span><span className="mt-1 block text-xs leading-relaxed text-fg-muted">{detail}</span></span><ArrowUpRight className="size-4 shrink-0 text-fg-muted" aria-hidden /></a>)}
          </DashboardPanel>
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
