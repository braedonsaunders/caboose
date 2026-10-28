import { DashboardMetricCard, DashboardPanel } from '@braedonsaunders/appkit-dashboard/primitives'
import { Alert, AlertDescription, AlertTitle, Button, PageContainer, PageHeader } from '@braedonsaunders/appkit-ui'
import { Cpu, HardDrive, MemoryStick, Monitor } from 'lucide-react'
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
  const quota = !me.operator && me.tenants.length === 1 ? me.tenants[0]!.quotas : null

  return (
    <PageContainer>
      <div className="space-y-6">
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

        <div className="grid gap-4 sm:grid-cols-2 xl:grid-cols-4">
          <DashboardMetricCard
            label="Computers"
            value={list.computers.length}
            detail={totals.running ? `${totals.running} running` : 'None running'}
            icon={<Monitor className="size-4" aria-hidden />}
          />
          <DashboardMetricCard
            label="Memory given"
            value={formatMemoryMb(totals.memoryMb)}
            detail={machine ? `${sharePercent(totals.memoryMb, machine.memoryMb)}% of ${formatMemoryMb(machine.memoryMb)}` : quota?.memoryMb ? `of a ${formatMemoryMb(quota.memoryMb)} quota` : undefined}
            tone={machine && totals.memoryMb > machine.memoryMb ? 'warning' : undefined}
            icon={<MemoryStick className="size-4" aria-hidden />}
          />
          <DashboardMetricCard
            label="vCPUs given"
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
