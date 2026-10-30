import { Monitor } from 'lucide-react'
import { Badge, EmptyState, Table, TableBody, TableCell, TableHead, TableHeader, TableRow } from '@braedonsaunders/appkit-ui'
import { formatIdleDuration, formatMemoryMb, type ComputerSummary, type Tenant } from '../api.js'
import { navigate, routeHref } from '../navigation.js'
import { stateLabel, stateTone } from '../state.js'

/** Every computer on the host, each row opening that computer's page. Each row shows its ownership chain. */
export function ComputersTable({ computers, tenants }: { computers: ComputerSummary[]; tenants: Tenant[] }) {
  if (!computers.length) return <EmptyState icon={<Monitor className="size-6" aria-hidden />} title="No computers yet" description="Create a computer to give someone a persistent workspace for their apps and files." />
  const tenantName = (id: string | null) => tenants.find(tenant => tenant.id === id)?.name ?? 'Assignment required'
  return (
    <Table containerClassName="border-0 shadow-none">
      <TableHeader>
        <TableRow noAnimate>
          <TableHead>Name</TableHead>
          <TableHead className="hidden sm:table-cell">Person</TableHead>
          <TableHead className="hidden md:table-cell">Tenant</TableHead>
          <TableHead>State</TableHead>
          <TableHead className="hidden sm:table-cell">Size</TableHead>
          <TableHead className="hidden md:table-cell">Screens</TableHead>
          <TableHead className="hidden lg:table-cell">Parks after</TableHead>
        </TableRow>
      </TableHeader>
      <TableBody>
        {computers.map(computer => {
          const href = routeHref({ page: 'computer', id: computer.id, tab: 'overview' })
          return (
            <TableRow key={computer.id} className="cursor-pointer" onClick={() => navigate(href)}>
              <TableCell>
                <a href={href} className="inline-flex items-start gap-3 font-medium hover:underline" onClick={event => { event.stopPropagation(); if (event.metaKey || event.ctrlKey || event.shiftKey || event.altKey) return; event.preventDefault(); navigate(href) }}>
                  <span className="grid size-9 shrink-0 place-items-center rounded-lg border border-border bg-bg-subtle text-fg-muted"><Monitor className="size-4" aria-hidden /></span><span className="min-w-0 break-words">{computer.settings.name}<span className="mt-1 block text-xs font-normal leading-relaxed text-fg-muted sm:hidden">{computer.person || 'Assignment required'}<br />{formatMemoryMb(computer.settings.memoryMb)} · {computer.settings.vcpus} vCPUs{computer.restartRequired ? ' · Restart to apply' : ''}</span></span>
                </a>
              </TableCell>
              <TableCell className="hidden text-sm sm:table-cell">{computer.personId ? computer.person : <span className="text-fg-muted">Assignment required</span>}</TableCell>
              <TableCell className="hidden text-sm md:table-cell">{tenantName(computer.tenantId)}</TableCell>
              <TableCell>
                <Badge variant={stateTone(computer.state)}>{stateLabel(computer.state)}</Badge>
                {computer.lastError ? <span className="ml-2 text-xs text-danger">error</span> : null}
              </TableCell>
              <TableCell className="hidden text-sm sm:table-cell">
                {formatMemoryMb(computer.settings.memoryMb)} · {computer.settings.vcpus} vCPUs
                {computer.restartRequired ? <span className="ml-2 text-xs text-fg-muted">restart to apply</span> : null}
              </TableCell>
              <TableCell className="hidden text-sm tabular-nums md:table-cell">{computer.clients.display}</TableCell>
              <TableCell className="hidden text-sm lg:table-cell">{formatIdleDuration(computer.settings.idleMs)}</TableCell>
            </TableRow>
          )
        })}
      </TableBody>
    </Table>
  )
}
