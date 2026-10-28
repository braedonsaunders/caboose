import * as React from 'react'
import { DashboardPanel } from '@braedonsaunders/appkit-dashboard/primitives'
import {
  Alert, AlertDescription, AlertTitle, Badge, Button, EmptyState, Input, Progress, Select, Spinner,
  Table, TableBody, TableCell, TableHead, TableHeader, TableRow, confirmDialog, toast,
} from '@braedonsaunders/appkit-ui'
import { Package } from 'lucide-react'
import { CabooseApiError, type CabooseClient } from '../../api.js'
import {
  appActions, catalogBusy, displayVersion, matchesQuery, packApps, packMissing, progressSummary,
  type CatalogApp, type CatalogOperation, type CatalogResponse,
} from '../../catalog.js'
import { AppIcon, NotRunningNotice, TabIntro, errorMessage, useVisibleInterval } from '../../components/common.js'
import type { ComputerHandle } from '../../useComputer.js'

/** Fast while an operation runs, so progress moves; slow otherwise, since each listing asks the computer. */
const BUSY_POLL_MS = 2_000
const IDLE_POLL_MS = 15_000

const ACTION_LABEL: Record<CatalogOperation, string> = { install: 'Install', update: 'Update', rollback: 'Roll back', remove: 'Remove' }

export function Apps({ client, computer, onUnauthorized }: { client: CabooseClient; computer: ComputerHandle; onUnauthorized: () => void }) {
  const running = computer.status?.state === 'running'
  const [catalog, setCatalog] = React.useState<CatalogResponse | null>(null)
  const [catalogError, setCatalogError] = React.useState<string | null>(null)
  const [query, setQuery] = React.useState('')
  const [pack, setPack] = React.useState('')
  const [starting, setStarting] = React.useState<string | null>(null)

  const handle = React.useCallback((failure: unknown, set: (message: string) => void) => {
    if (failure instanceof CabooseApiError && failure.isUnauthorized) onUnauthorized()
    else set(errorMessage(failure))
  }, [onUnauthorized])

  const refreshCatalog = React.useCallback(async () => {
    try {
      setCatalog(await client.catalog())
      setCatalogError(null)
    } catch (failure) {
      handle(failure, setCatalogError)
    }
  }, [client, handle])

  const busy = catalogBusy(catalog)
  React.useEffect(() => { void refreshCatalog() }, [refreshCatalog, running])
  useVisibleInterval(() => void refreshCatalog(), busy ? BUSY_POLL_MS : IDLE_POLL_MS)

  async function start(app: CatalogApp, operation: CatalogOperation) {
    if (operation === 'remove' && !await confirmDialog({
      title: `Remove ${app.name}?`,
      message: 'The app is uninstalled from this computer. Files made with it stay in the home folder.',
      confirmLabel: 'Remove',
      tone: 'danger',
    })) return
    setStarting(app.id)
    try {
      await client.startCatalogOperation(app.id, operation)
    } catch (failure) {
      toast.error(errorMessage(failure))
    } finally {
      setStarting(null)
      await refreshCatalog()
    }
  }

  async function installPack(id: string, name: string) {
    setStarting(`pack:${id}`)
    try {
      await client.installPack(id)
      toast.success(`Installing ${name}. Apps already installed are skipped.`)
    } catch (failure) {
      toast.error(errorMessage(failure))
    } finally {
      setStarting(null)
      await refreshCatalog()
    }
  }

  const shown = catalog ? (pack ? packApps(catalog, pack) : catalog.apps).filter(app => matchesQuery(app, query)) : []
  const operations = catalog?.apps.filter(app => app.progress && app.progress.phase !== 'finished') ?? []
  const selectedPack = catalog?.packs.find(entry => entry.id === pack)
  const missing = catalog && pack ? packMissing(catalog, pack) : 0

  return (
    <div className="space-y-6">
      <TabIntro
        description="Optional apps from the Caboose catalog: install, update, roll back or remove them on this computer. Release versions are pinned and never change on their own."
        actions={
          <Input
            className="w-56"
            type="search"
            placeholder="Search apps"
            aria-label="Search apps"
            value={query}
            onChange={event => setQuery(event.target.value)}
          />
        }
      />

      <NotRunningNotice client={client} computer={computer}>
        The catalog shows what was installed when the computer last ran. Wake it to install, update or remove apps.
      </NotRunningNotice>

      {operations.length ? (
        <DashboardPanel title="Operations" icon={<Package className="size-4" aria-hidden />}>
          <ul className="space-y-3">
            {operations.map(app => <OperationRow key={app.id} app={app} />)}
          </ul>
        </DashboardPanel>
      ) : null}

      <DashboardPanel
        title="Catalog"
        icon={<Package className="size-4" aria-hidden />}
        actions={catalog ? (
          <div className="flex flex-wrap items-center gap-2">
            <Select className="w-48" aria-label="Pack" value={pack} onChange={event => setPack(event.target.value)}>
              <option value="">All apps</option>
              {catalog.packs.map(entry => <option key={entry.id} value={entry.id}>{entry.name}</option>)}
            </Select>
            {selectedPack ? (
              <Button
                size="sm"
                disabled={!running || busy || missing === 0 || starting !== null}
                onClick={() => void installPack(selectedPack.id, selectedPack.name)}
              >
                {missing ? `Install ${selectedPack.name} (${missing})` : 'All installed'}
              </Button>
            ) : null}
          </div>
        ) : null}
      >
        {catalogError ? (
          <Alert variant="destructive" className="mb-3"><AlertTitle>The catalog could not be read</AlertTitle><AlertDescription>{catalogError}</AlertDescription></Alert>
        ) : null}
        {!catalog ? (
          catalogError ? null : <div className="flex items-center gap-2 text-sm text-fg-muted"><Spinner size={16} />Reading the catalog…</div>
        ) : shown.length === 0 ? (
          <EmptyState icon={<Package className="size-6" aria-hidden />} title="No apps match" description="Try another search or pack." />
        ) : (
          <Table containerClassName="border-0 shadow-none">
            <TableHeader>
              <TableRow noAnimate>
                <TableHead>App</TableHead>
                <TableHead className="hidden md:table-cell">Category</TableHead>
                <TableHead>Version</TableHead>
                <TableHead>Status</TableHead>
                <TableHead className="text-right">Actions</TableHead>
              </TableRow>
            </TableHeader>
            <TableBody>
              {shown.map(app => {
                return (
                  <TableRow key={app.id}>
                    <TableCell>
                      <div className="flex min-w-0 items-center gap-3">
                        <AppIcon src={app.iconData} name={app.name} size={32} />
                        <div className="min-w-0">
                          <div className="truncate font-medium">{app.name}</div>
                          <div className="truncate text-xs text-fg-muted">{app.summary}</div>
                        </div>
                      </div>
                    </TableCell>
                    <TableCell className="hidden text-sm text-fg-muted md:table-cell">{app.category}</TableCell>
                    <TableCell className="text-sm">
                      <VersionCell app={app} />
                    </TableCell>
                    <TableCell>
                      <StatusCell app={app} />
                    </TableCell>
                    <TableCell>
                      <div className="flex flex-wrap justify-end gap-2">
                        {appActions(app).map(operation => (
                          <Button
                            key={operation}
                            size="sm"
                            variant={operation === 'remove' ? 'ghost' : operation === 'install' || operation === 'update' ? 'default' : 'outline'}
                            disabled={!running || busy || starting !== null}
                            title={!running ? 'Wake the computer first.' : busy ? 'Another operation is running.' : undefined}
                            onClick={() => void start(app, operation)}
                          >
                            {ACTION_LABEL[operation]}
                          </Button>
                        ))}
                      </div>
                    </TableCell>
                  </TableRow>
                )
              })}
            </TableBody>
          </Table>
        )}
      </DashboardPanel>
    </div>
  )
}

function VersionCell({ app }: { app: CatalogApp }) {
  if (app.installedVersion) {
    return (
      <div>
        <div title={app.installedVersion}>{displayVersion(app.installedVersion)}</div>
        {app.updateAvailable && app.pinnedVersion ? <div className="text-xs text-fg-muted">{app.pinnedVersion} available</div> : null}
      </div>
    )
  }
  return <span className="text-fg-muted">{app.pinnedVersion ?? 'Debian'}</span>
}

function StatusCell({ app }: { app: CatalogApp }) {
  if (app.progress && app.progress.phase !== 'finished') {
    const { label, percent } = progressSummary(app.progress)
    return <Badge variant={app.progress.phase === 'failed' ? 'destructive' : 'info'}>{percent !== undefined ? `${label} ${percent}%` : label}</Badge>
  }
  if (app.interrupted) return <Badge variant="warning" title="An operation was running when the computer stopped. Try it again.">Interrupted</Badge>
  if (app.lastError) return <Badge variant="destructive" title={app.lastError}>Last change failed</Badge>
  if (app.updateAvailable) return <Badge variant="warning">Update available</Badge>
  if (app.installedVersion) return <Badge variant="success">Installed</Badge>
  return <Badge variant="outline">Not installed</Badge>
}

function OperationRow({ app }: { app: CatalogApp }) {
  const progress = app.progress!
  const { label, percent } = progressSummary(progress)
  return (
    <li className="space-y-1.5">
      <div className="flex items-center gap-2 text-sm">
        <AppIcon src={app.iconData} name={app.name} size={20} />
        <span className="font-medium">{app.name}</span>
        <span className={progress.phase === 'failed' ? 'text-danger' : 'text-fg-muted'}>{label}{percent !== undefined ? ` · ${percent}%` : ''}</span>
      </div>
      {progress.phase === 'failed' ? (
        progress.message ? <pre className="max-h-40 overflow-auto whitespace-pre-wrap break-words rounded-md bg-bg-subtle p-2 font-mono text-xs">{progress.message}</pre> : null
      ) : (
        <Progress value={progress.phase === 'queued' ? 0 : percent} aria-label={`${app.name}: ${label}`} />
      )}
    </li>
  )
}
