import { Badge, Table, TableBody, TableCell, TableHead, TableHeader, TableRow } from '@braedonsaunders/appkit-ui'
import { formatIdleDuration, formatMemoryMb, type ComputerSummary } from '../api.js'
import { navigate, routeHref } from '../navigation.js'
import { stateLabel, stateTone } from '../state.js'

/** Every computer on the host, each row opening that computer's page. */
export function ComputersTable({ computers }: { computers: ComputerSummary[] }) {
  return (
    <Table containerClassName="border-0 shadow-none">
      <TableHeader>
        <TableRow noAnimate>
          <TableHead>Name</TableHead>
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
                <a href={href} className="font-medium hover:underline" onClick={event => { event.preventDefault(); event.stopPropagation(); navigate(href) }}>
                  {computer.settings.name}
                </a>
              </TableCell>
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
