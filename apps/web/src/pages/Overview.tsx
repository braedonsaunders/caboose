import { DashboardMetricCard, DashboardPanel } from '@braedonsaunders/appkit-dashboard/primitives'
import {
  Alert, AlertDescription, AlertTitle, Badge, PageContainer, PageHeader,
  Table, TableBody, TableCell, TableHead, TableHeader, TableRow,
} from '@braedonsaunders/appkit-ui'
import { Cpu, HardDrive, MemoryStick, Monitor } from 'lucide-react'
import { formatIdleDuration, formatMemoryMb } from '../api.js'
import { formatBytes } from '../files.js'
import { healthProblems, sharePercent, upgradeLabel } from '../host.js'
import { navigate } from '../navigation.js'
import { stateLabel, stateTone } from '../state.js'
import type { ComputerHandle } from '../useComputer.js'
import type { HostHandle } from '../useHost.js'
import { RollingWordmark } from '../brand/Logo.js'

/** The host at a glance: what its computers are given of the machine, and anything that needs attention. */
export function Overview({ computer, host }: { computer: ComputerHandle; host: HostHandle }) {
  const { status, error } = computer
  const { info, health } = host

  if (!status) {
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

  const machine = health?.machine
  const problems = health ? healthProblems(health) : []
  const running = status.state === 'running' ? 1 : 0
  const upgrade = status.upgrade
  const open = () => navigate('/computer')

  return (
    <PageContainer>
      <div className="space-y-6">
        <PageHeader
          title="Overview"
          description={info ? `caboose-host ${info.version}, running computers as ${info.runtime === 'container' ? 'containers' : 'microVMs'}.` : 'This host and the computers it runs.'}
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
        {status.lastError ? (
          <Alert variant="destructive">
            <AlertTitle>{status.settings.name}: last lifecycle error</AlertTitle>
            <AlertDescription className="font-mono text-xs break-all">{status.lastError}</AlertDescription>
          </Alert>
        ) : null}
        {upgrade?.state === 'failed' ? (
          <Alert variant="warning">
            <AlertTitle>{status.settings.name}: {upgradeLabel(upgrade)}</AlertTitle>
            {upgrade.message ? <AlertDescription className="break-words">{upgrade.message}</AlertDescription> : null}
          </Alert>
        ) : null}

        <div className="grid gap-4 sm:grid-cols-2 xl:grid-cols-4">
          <DashboardMetricCard
            label="Computers"
            value={1}
            detail={running ? '1 running' : 'None running'}
            icon={<Monitor className="size-4" aria-hidden />}
          />
          <DashboardMetricCard
            label="Memory given"
            value={formatMemoryMb(status.settings.memoryMb)}
            detail={machine
              ? `${sharePercent(status.settings.memoryMb, machine.memoryMb)}% of ${formatMemoryMb(machine.memoryMb)}`
              : undefined}
            icon={<MemoryStick className="size-4" aria-hidden />}
          />
          <DashboardMetricCard
            label="vCPUs given"
            value={status.settings.vcpus}
            detail={machine ? `of ${machine.cpus} CPUs on this machine` : undefined}
            icon={<Cpu className="size-4" aria-hidden />}
          />
          <DashboardMetricCard
            label="Disk free"
            value={machine?.disk ? formatBytes(machine.disk.freeBytes) : '—'}
            detail={machine?.disk ? `of ${formatBytes(machine.disk.totalBytes)}` : undefined}
            icon={<HardDrive className="size-4" aria-hidden />}
          />
        </div>

        <DashboardPanel title="Computers" icon={<Monitor className="size-4" aria-hidden />}>
          <Table containerClassName="border-0 shadow-none">
            <TableHeader>
              <TableRow noAnimate>
                <TableHead>Name</TableHead>
                <TableHead>State</TableHead>
                <TableHead className="hidden sm:table-cell">Size</TableHead>
                <TableHead className="hidden md:table-cell">Screens</TableHead>
                <TableHead className="hidden md:table-cell">Parks after</TableHead>
              </TableRow>
            </TableHeader>
            <TableBody>
              <TableRow className="cursor-pointer" onClick={open}>
                <TableCell>
                  <a href="/computer" className="font-medium hover:underline" onClick={event => { event.preventDefault(); open() }}>
                    {status.settings.name}
                  </a>
                </TableCell>
                <TableCell><Badge variant={stateTone(status.state)}>{stateLabel(status.state)}</Badge></TableCell>
                <TableCell className="hidden text-sm sm:table-cell">
                  {formatMemoryMb(status.settings.memoryMb)} · {status.settings.vcpus} vCPUs
                  {status.restartRequired ? <span className="ml-2 text-xs text-fg-muted">restart to apply</span> : null}
                </TableCell>
                <TableCell className="hidden text-sm tabular-nums md:table-cell">{status.clients.display}</TableCell>
                <TableCell className="hidden text-sm md:table-cell">{formatIdleDuration(status.settings.idleMs)}</TableCell>
              </TableRow>
            </TableBody>
          </Table>
        </DashboardPanel>
      </div>
    </PageContainer>
  )
}
