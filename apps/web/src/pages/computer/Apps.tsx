import * as React from 'react'
import { DashboardPanel } from '@braedonsaunders/appkit-dashboard/primitives'
import {
  Alert, AlertDescription, AlertTitle, Badge, Button, EmptyState, Input, Progress, Spinner,
  Table, TableBody, TableCell, TableHead, TableHeader, TableRow, confirmDialog, toast,
} from '@braedonsaunders/appkit-ui'
import { BadgeCheck, Layers, Package, RefreshCw } from 'lucide-react'
import { CabooseApiError, type CabooseClient } from '../../api.js'
import {
  actionLabel, appActions, appendPage, catalogBusy, displayVersion, nextOffset, packApps, packMissing, progressSummary,
  withLiveState, type CatalogApp, type CatalogOperation, type CatalogResponse,
} from '../../catalog.js'
import { AppIcon, NotRunningNotice, TabIntro, errorMessage, useVisibleInterval } from '../../components/common.js'
import type { ComputerHandle } from '../../useComputer.js'

/** Fast while an operation runs, so progress moves; slow otherwise. The listing never wakes the computer. */
const BUSY_POLL_MS = 2_000
const IDLE_POLL_MS = 15_000
/** A search waits for a pause in typing. */
const SEARCH_DEBOUNCE_MS = 300

/** The Library pages loaded so far for one search and category. */
interface Library {
  apps: CatalogApp[]
  next: number | null
  total: number
}

export function Apps({ client, computer, onUnauthorized }: { client: CabooseClient; computer: ComputerHandle; onUnauthorized: () => void }) {
  const running = computer.status?.state === 'running'
  const [catalog, setCatalog] = React.useState<CatalogResponse | null>(null)
  const [catalogError, setCatalogError] = React.useState<string | null>(null)
  const [search, setSearch] = React.useState('')
  const [query, setQuery] = React.useState('')
  const [category, setCategory] = React.useState('')
  const [library, setLibrary] = React.useState<Library | null>(null)
  const [categories, setCategories] = React.useState<string[]>([])
  /** The page that failed, so Try again asks for it again. */
  const [libraryError, setLibraryError] = React.useState<{ message: string; offset: number } | null>(null)
  const [loading, setLoading] = React.useState(false)
  const [starting, setStarting] = React.useState<string | null>(null)
  const generation = React.useRef(0)

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

  React.useEffect(() => {
    const timer = window.setTimeout(() => setQuery(search.trim()), SEARCH_DEBOUNCE_MS)
    return () => window.clearTimeout(timer)
  }, [search])

  /** Reads the page at `offset` for the current search and category; a newer request supersedes it. */
  const loadPage = React.useCallback(async (offset: number) => {
    const ticket = ++generation.current
    setLoading(true)
    setLibraryError(null)
    if (offset === 0) setLibrary(null)
    try {
      const page = await client.discoverCatalog({ q: query, category, offset })
      if (ticket !== generation.current) return
      setLibrary(current => ({
        apps: appendPage(offset > 0 && current ? current.apps : [], page.apps),
        next: nextOffset(page),
        total: page.total,
      }))
      setCategories(page.categories)
    } catch (failure) {
      if (ticket === generation.current) handle(failure, message => setLibraryError({ message, offset }))
    } finally {
      if (ticket === generation.current) setLoading(false)
    }
  }, [client, query, category, handle])

  React.useEffect(() => { void loadPage(0) }, [loadPage])

  const loadMore = React.useCallback(() => {
    if (!loading && !libraryError && library?.next != null) void loadPage(library.next)
  }, [loading, libraryError, library, loadPage])

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

  const unfiltered = !query && !category
  const rows = withLiveState(library?.apps ?? [], catalog)
  const updates = catalog?.apps.filter(app => app.updateAvailable) ?? []
  const operations = catalog?.apps.filter(app => app.progress && app.progress.phase !== 'finished') ?? []
  const actions = { running, busy, starting, start }

  return (
    <div className="space-y-6">
      <TabIntro
        description="Every app this computer can add, in one list: Caboose's curated apps first, then Flathub's. Apps update on their own; Update now installs a waiting version right away."
        actions={
          <Input
            className="w-56"
            type="search"
            placeholder="Search apps"
            aria-label="Search apps"
            value={search}
            onChange={event => setSearch(event.target.value)}
          />
        }
      />

      <NotRunningNotice client={client} computer={computer}>
        The Library works while the computer is parked and shows what was installed when it last ran. Wake it to install, update or remove apps.
      </NotRunningNotice>

      {catalogError ? (
        <Alert variant="destructive"><AlertTitle>The catalog could not be read</AlertTitle><AlertDescription>{catalogError}</AlertDescription></Alert>
      ) : null}

      {operations.length ? (
        <DashboardPanel title="Operations" icon={<Package className="size-4" aria-hidden />}>
          <ul className="space-y-3">
            {operations.map(app => <OperationRow key={app.id} app={app} />)}
          </ul>
        </DashboardPanel>
      ) : null}

      {unfiltered && catalog?.packs.length ? (
        <DashboardPanel title="Collections" icon={<Layers className="size-4" aria-hidden />}>
          <div className="flex gap-3 overflow-x-auto pb-1">
            {catalog.packs.map(pack => {
              const apps = packApps(catalog, pack.id)
              const missing = packMissing(catalog, pack.id)
              return (
                <div key={pack.id} className="flex w-56 shrink-0 flex-col gap-2 rounded-lg border border-border p-3" title={apps.map(app => app.name).join(', ')}>
                  <div className="flex gap-1">{apps.slice(0, 4).map(app => <AppIcon key={app.id} src={app.iconData} name={app.name} size={24} />)}</div>
                  <div className="truncate font-medium">{pack.name}</div>
                  <div className="text-xs text-fg-muted">{apps.length === 1 ? '1 app' : `${apps.length} apps`}{missing ? ` · ${missing} to install` : ' · all installed'}</div>
                  <Button
                    size="sm"
                    variant={missing ? 'default' : 'outline'}
                    disabled={!running || busy || missing === 0 || starting !== null}
                    title={!running ? 'Wake the computer first.' : busy ? 'Another operation is running.' : undefined}
                    onClick={() => void installPack(pack.id, pack.name)}
                  >
                    {missing ? 'Get pack' : 'All installed'}
                  </Button>
                </div>
              )
            })}
          </div>
        </DashboardPanel>
      ) : null}

      {unfiltered && updates.length ? (
        <DashboardPanel title="Updates" icon={<RefreshCw className="size-4" aria-hidden />}>
          <p className="mb-3 text-sm text-fg-muted">These apps have a newer version waiting. They update on their own; Update now installs it right away.</p>
          <AppTable apps={updates} {...actions} />
        </DashboardPanel>
      ) : null}

      <DashboardPanel
        title="Library"
        icon={<Package className="size-4" aria-hidden />}
        actions={library ? (
          <div className="flex items-center gap-2 text-sm text-fg-muted">
            {loading ? <Spinner size={14} /> : null}
            {library.total === 1 ? '1 app' : `${library.total.toLocaleString()} apps`}
          </div>
        ) : null}
      >
        {categories.length ? (
          <div className="mb-3 flex gap-2 overflow-x-auto pb-1" role="group" aria-label="Category">
            {['', ...categories].map(value => (
              <Button
                key={value || 'all'}
                className="shrink-0"
                size="sm"
                variant={category === value ? 'default' : 'outline'}
                aria-pressed={category === value}
                onClick={() => setCategory(value)}
              >
                {value || 'All'}
              </Button>
            ))}
          </div>
        ) : null}
        {libraryError ? (
          <Alert variant="destructive" className="mb-3">
            <AlertTitle>The Library could not be read</AlertTitle>
            <AlertDescription>
              {libraryError.message}{' '}
              <Button size="sm" variant="outline" onClick={() => void loadPage(libraryError.offset)}>Try again</Button>
            </AlertDescription>
          </Alert>
        ) : null}
        {!library ? (
          libraryError ? null : <div className="flex items-center gap-2 text-sm text-fg-muted"><Spinner size={16} />Reading the Library…</div>
        ) : rows.length === 0 ? (
          loading ? null : <EmptyState icon={<Package className="size-6" aria-hidden />} title="No apps match" description="Try another search or category." />
        ) : (
          <>
            <AppTable apps={rows} {...actions} />
            {library.next !== null ? <MoreResults count={rows.length} loading={loading} onMore={loadMore} /> : null}
          </>
        )}
      </DashboardPanel>
    </div>
  )
}

interface AppTableProps {
  apps: CatalogApp[]
  running: boolean
  busy: boolean
  starting: string | null
  start: (app: CatalogApp, operation: CatalogOperation) => Promise<void>
}

function AppTable({ apps, running, busy, starting, start }: AppTableProps) {
  return (
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
        {apps.map(app => (
          <TableRow key={app.id}>
            <TableCell>
              <div className="flex min-w-0 items-center gap-3">
                <AppIcon src={app.iconData} name={app.name} size={32} />
                <div className="min-w-0">
                  <div className="truncate font-medium">{app.name}</div>
                  <div className="truncate text-xs text-fg-muted">{app.summary}</div>
                  <Credits app={app} />
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
                    variant={operation === 'remove' ? 'ghost' : 'default'}
                    disabled={!running || busy || starting !== null}
                    title={!running ? 'Wake the computer first.' : busy ? 'Another operation is running.' : undefined}
                    onClick={() => void start(app, operation)}
                  >
                    {actionLabel(app, operation)}
                  </Button>
                ))}
              </div>
            </TableCell>
          </TableRow>
        ))}
      </TableBody>
    </Table>
  )
}

/** The publisher, with Flathub's verified mark, and the license. */
function Credits({ app }: { app: CatalogApp }) {
  if (!app.developer && !app.license) return null
  return (
    <div className="flex min-w-0 items-center gap-1 text-xs text-fg-muted">
      {app.developer ? <span className="truncate">{app.developer}</span> : null}
      {app.developer && app.verified ? <BadgeCheck className="size-3.5 shrink-0 text-info" aria-label="Verified" /> : null}
      {app.license ? <span className="truncate">{app.developer ? `· ${app.license}` : app.license}</span> : null}
    </div>
  )
}

/** Loads the next page when it scrolls into view, or when pressed. */
function MoreResults({ count, loading, onMore }: { count: number; loading: boolean; onMore: () => void }) {
  const sentinel = React.useRef<HTMLDivElement>(null)
  const latest = React.useRef(onMore)
  latest.current = onMore
  React.useEffect(() => {
    const node = sentinel.current
    if (!node || typeof IntersectionObserver === 'undefined') return
    const observer = new IntersectionObserver(entries => { if (entries.some(entry => entry.isIntersecting)) latest.current() }, { rootMargin: '400px' })
    observer.observe(node)
    return () => observer.disconnect()
  }, [count])
  return (
    <div ref={sentinel} className="mt-3 flex justify-center">
      <Button size="sm" variant="outline" disabled={loading} onClick={onMore}>
        {loading ? <Spinner size={14} /> : null}Show more
      </Button>
    </div>
  )
}

function VersionCell({ app }: { app: CatalogApp }) {
  if (app.installedVersion) {
    return (
      <div>
        <div title={app.installedVersion}>{displayVersion(app.installedVersion, app.source)}</div>
        {app.updateAvailable && app.latestVersion ? <div className="text-xs text-fg-muted">{displayVersion(app.latestVersion, app.source)} available</div> : null}
      </div>
    )
  }
  return <span className="text-fg-muted">{app.latestVersion ? displayVersion(app.latestVersion, app.source) : '—'}</span>
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
