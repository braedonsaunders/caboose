import * as React from 'react'
import { DashboardPanel } from '@braedonsaunders/appkit-dashboard/primitives'
import {
  Alert, AlertDescription, AlertTitle, Button, EmptyState, PageContainer, PageHeader, Spinner, Switch,
  Table, TableBody, TableCell, TableHead, TableHeader, TableRow, confirmDialog, promptDialog, toast,
} from '@braedonsaunders/appkit-ui'
import { ArrowUp, ChevronRight, Download, File, Folder, FolderPlus, MonitorUp, Pencil, RefreshCw, Trash2, Upload } from 'lucide-react'
import { CabooseApiError, type CabooseClient } from '../api.js'
import {
  breadcrumbs, formatBytes, joinPath, nameProblem, normalizeFsPath, parentPath, visibleItems,
  type FileItem, type FileSortKey,
} from '../files.js'
import { errorMessage } from '../components/common.js'
import { navigate, useSearchParam } from '../navigation.js'
import { isTransitioning } from '../state.js'
import type { ComputerHandle } from '../useComputer.js'

function filesHref(path: string): string {
  return path ? `/files?path=${encodeURIComponent(path)}` : '/files'
}

export function Files({ client, computer, onUnauthorized }: { client: CabooseClient; computer: ComputerHandle; onUnauthorized: () => void }) {
  const path = normalizeFsPath(useSearchParam('path'))
  const state = computer.status?.state
  // Every /v1/fs request wakes a parked computer, so a parked one is only woken when asked.
  const [allowWake, setAllowWake] = React.useState(false)
  const canBrowse = state === 'running' || allowWake
  const [items, setItems] = React.useState<FileItem[] | null>(null)
  const [loadedPath, setLoadedPath] = React.useState<string | null>(null)
  const [error, setError] = React.useState<{ status: number; message: string } | null>(null)
  const [loading, setLoading] = React.useState(false)
  const [showHidden, setShowHidden] = React.useState(false)
  const [sort, setSort] = React.useState<{ key: FileSortKey; dir: 'asc' | 'desc' }>({ key: 'name', dir: 'asc' })
  const [busy, setBusy] = React.useState<string | null>(null)
  const [uploads, setUploads] = React.useState<{ name: string; index: number; total: number } | null>(null)
  const [dragging, setDragging] = React.useState(false)
  const uploadInput = React.useRef<HTMLInputElement>(null)
  const request = React.useRef(0)

  const fail = React.useCallback((failure: unknown): boolean => {
    if (failure instanceof CabooseApiError && failure.isUnauthorized) {
      onUnauthorized()
      return true
    }
    return false
  }, [onUnauthorized])

  // The handle is a new object each render; its refresh is stable, so loading depends on that alone.
  const refreshComputer = computer.refresh
  const load = React.useCallback(async (target: string) => {
    const id = ++request.current
    setLoading(true)
    try {
      const listed = await client.listFiles(target)
      if (id !== request.current) return
      setItems(listed)
      setLoadedPath(target)
      setError(null)
    } catch (failure) {
      if (id !== request.current || fail(failure)) return
      setError({ status: failure instanceof CabooseApiError ? failure.status : 0, message: errorMessage(failure) })
    } finally {
      if (id === request.current) setLoading(false)
      void refreshComputer()
    }
  }, [client, refreshComputer, fail])

  React.useEffect(() => {
    if (canBrowse) void load(path)
  }, [canBrowse, load, path])

  const refresh = () => load(path)

  async function act(label: string, work: () => Promise<unknown>, done?: string) {
    setBusy(label)
    try {
      await work()
      if (done) toast.success(done)
    } catch (failure) {
      if (!fail(failure)) toast.error(errorMessage(failure))
    } finally {
      setBusy(null)
      await refresh()
    }
  }

  async function download(item: FileItem) {
    setBusy(`download:${item.name}`)
    try {
      const response = await client.downloadFile(joinPath(path, item.name))
      const blob = await response.blob()
      const url = URL.createObjectURL(blob)
      const anchor = document.createElement('a')
      anchor.href = url
      anchor.download = item.name
      document.body.append(anchor)
      anchor.click()
      anchor.remove()
      window.setTimeout(() => URL.revokeObjectURL(url), 60_000)
    } catch (failure) {
      if (!fail(failure)) toast.error(errorMessage(failure))
    } finally {
      setBusy(null)
    }
  }

  async function upload(files: File[]) {
    if (!files.length) return
    const directory = path
    const saved: string[] = []
    try {
      for (const [index, file] of files.entries()) {
        setUploads({ name: file.name, index: index + 1, total: files.length })
        const problem = nameProblem(file.name)
        if (problem) {
          toast.error(`${file.name}: ${problem}`)
          continue
        }
        try {
          saved.push(await client.uploadFile(directory, file.name, file))
        } catch (failure) {
          if (fail(failure)) return
          toast.error(`${file.name}: ${errorMessage(failure)}`)
        }
      }
    } finally {
      setUploads(null)
      if (uploadInput.current) uploadInput.current.value = ''
      await load(directory)
    }
    if (saved.length === 1) toast.success(`Uploaded ${saved[0]!.split('/').pop()}.`)
    else if (saved.length > 1) toast.success(`Uploaded ${saved.length} files.`)
  }

  async function newFolder() {
    const name = await promptDialog({ title: 'New folder', label: 'Name', placeholder: 'Untitled folder', confirmLabel: 'Create' })
    if (name === null) return
    const problem = nameProblem(name)
    if (problem) return void toast.error(problem)
    await act('mkdir', () => client.createFolder(joinPath(path, name)))
  }

  async function rename(item: FileItem) {
    const name = await promptDialog({ title: `Rename “${item.name}”`, label: 'Name', initialValue: item.name, confirmLabel: 'Rename' })
    if (name === null || name === item.name) return
    const problem = nameProblem(name)
    if (problem) return void toast.error(problem)
    await act(`rename:${item.name}`, () => client.moveFile(joinPath(path, item.name), joinPath(path, name)))
  }

  async function trash(item: FileItem) {
    const confirmed = await confirmDialog({
      title: `Move “${item.name}” to the Trash?`,
      message: 'It goes to the Trash in your computer, where you can restore it from the file manager.',
      confirmLabel: 'Move to Trash',
      tone: 'danger',
    })
    if (confirmed) await act(`trash:${item.name}`, () => client.trashFile(joinPath(path, item.name)), `Moved ${item.name} to the Trash.`)
  }

  async function openOnComputer(item: FileItem) {
    await act(`open:${item.name}`, () => client.openOnComputer(joinPath(path, item.name)), `${item.name} is opening on your computer's screen.`)
  }

  function sortBy(key: FileSortKey) {
    setSort(current => current.key === key ? { key, dir: current.dir === 'asc' ? 'desc' : 'asc' } : { key, dir: key === 'name' ? 'asc' : 'desc' })
  }

  const shown = items && loadedPath === path ? visibleItems(items, { showHidden, sort: sort.key, dir: sort.dir }) : null
  const crumbs = breadcrumbs(path)
  const waking = state !== undefined && isTransitioning(state)
  const disabled = !canBrowse || busy !== null || uploads !== null

  return (
    <PageContainer>
      <div className="space-y-6">
        <PageHeader
          title="Files"
          description="Your computer's home folder. Download files, upload into the folder you are in, or open something on the computer's screen."
          actions={canBrowse ? (
            <div className="flex flex-wrap gap-2">
              <Button variant="outline" onClick={() => void newFolder()} disabled={disabled}>
                <FolderPlus className="size-4" aria-hidden />New folder
              </Button>
              <Button onClick={() => uploadInput.current?.click()} disabled={disabled}>
                <Upload className="size-4" aria-hidden />Upload
              </Button>
              <input ref={uploadInput} type="file" multiple hidden onChange={event => void upload([...(event.target.files ?? [])])} />
            </div>
          ) : null}
        />

        {!canBrowse ? (
          <Alert variant="info">
            <AlertTitle>{waking ? 'Your computer is starting up' : 'Your computer is parked'}</AlertTitle>
            <AlertDescription>
              <div className="flex flex-wrap items-center gap-3">
                <span className="min-w-0 flex-1">Browsing its files wakes it, and it parks again after it has been idle.</span>
                <Button size="sm" onClick={() => setAllowWake(true)}>Wake and browse</Button>
              </div>
            </AlertDescription>
          </Alert>
        ) : null}

        {canBrowse ? (
          <DashboardPanel
            title={
              <nav aria-label="Folder" className="flex min-w-0 flex-wrap items-center gap-1 text-sm">
                {crumbs.map((crumb, index) => (
                  <React.Fragment key={crumb.path}>
                    {index > 0 ? <ChevronRight className="size-3.5 text-muted-foreground" aria-hidden /> : null}
                    {index === crumbs.length - 1 ? (
                      <span className="font-semibold" aria-current="page">{crumb.name}</span>
                    ) : (
                      <a href={filesHref(crumb.path)} className="text-muted-foreground hover:text-fg hover:underline"
                        onClick={event => { event.preventDefault(); navigate(filesHref(crumb.path)) }}>
                        {crumb.name}
                      </a>
                    )}
                  </React.Fragment>
                ))}
              </nav>
            }
            actions={
              <div className="flex items-center gap-3">
                <label className="flex items-center gap-2 text-xs text-muted-foreground">
                  <Switch checked={showHidden} onChange={event => setShowHidden(event.target.checked)} />
                  Hidden files
                </label>
                <Button size="sm" variant="ghost" disabled={!path} onClick={() => navigate(filesHref(parentPath(path)))} aria-label="Enclosing folder">
                  <ArrowUp className="size-4" aria-hidden />
                </Button>
                <Button size="sm" variant="ghost" disabled={loading} onClick={() => void refresh()} aria-label="Refresh">
                  <RefreshCw className={`size-4 ${loading ? 'animate-spin' : ''}`} aria-hidden />
                </Button>
              </div>
            }
          >
            <div
              className={`relative rounded-md ${dragging ? 'outline-2 outline-dashed outline-primary' : ''}`}
              onDragOver={event => { if (event.dataTransfer.types.includes('Files')) { event.preventDefault(); setDragging(true) } }}
              onDragLeave={event => { if (event.currentTarget === event.target) setDragging(false) }}
              onDrop={event => {
                event.preventDefault()
                setDragging(false)
                if (!disabled) void upload([...event.dataTransfer.files])
              }}
            >
              {uploads ? (
                <div className="mb-3 flex items-center gap-2 text-sm text-muted-foreground">
                  <Spinner size={16} />Uploading {uploads.name}{uploads.total > 1 ? ` (${uploads.index} of ${uploads.total})` : ''}…
                </div>
              ) : null}
              {error ? (
                <Alert variant="destructive">
                  <AlertTitle>{error.status === 404 ? 'This folder is not there' : error.status === 403 ? 'This folder cannot be read' : 'The folder could not be listed'}</AlertTitle>
                  <AlertDescription>
                    <div className="flex flex-wrap items-center gap-3">
                      <span className="min-w-0 flex-1">{error.message}</span>
                      {path ? <Button size="sm" variant="outline" onClick={() => navigate('/files')}>Go to Home</Button> : null}
                      <Button size="sm" variant="outline" onClick={() => void refresh()}>Try again</Button>
                    </div>
                  </AlertDescription>
                </Alert>
              ) : shown === null ? (
                <div className="flex items-center gap-2 py-6 text-sm text-muted-foreground">
                  <Spinner size={16} />{state === 'running' ? 'Listing…' : 'Waking your computer…'}
                </div>
              ) : shown.length === 0 ? (
                <EmptyState
                  icon={<Folder className="size-6" aria-hidden />}
                  title="This folder is empty"
                  description="Drop files here or use Upload to add them."
                />
              ) : (
                <Table containerClassName="border-0 shadow-none">
                  <TableHeader>
                    <TableRow noAnimate>
                      <SortHead label="Name" active={sort.key === 'name'} dir={sort.dir} onClick={() => sortBy('name')} />
                      <SortHead label="Size" active={sort.key === 'size'} dir={sort.dir} onClick={() => sortBy('size')} className="hidden w-28 sm:table-cell" />
                      <SortHead label="Modified" active={sort.key === 'mtime'} dir={sort.dir} onClick={() => sortBy('mtime')} className="hidden w-48 md:table-cell" />
                      <TableHead className="w-px text-right"><span className="sr-only">Actions</span></TableHead>
                    </TableRow>
                  </TableHeader>
                  <TableBody>
                    {shown.map(item => {
                      const target = joinPath(path, item.name)
                      return (
                        <TableRow key={item.identity + item.name}>
                          <TableCell>
                            <div className="flex min-w-0 items-center gap-2">
                              {item.kind === 'directory'
                                ? <Folder className="size-4 shrink-0 text-primary" aria-hidden />
                                : <File className="size-4 shrink-0 text-muted-foreground" aria-hidden />}
                              {item.kind === 'directory' ? (
                                <a href={filesHref(target)} className="truncate font-medium hover:underline"
                                  onClick={event => { event.preventDefault(); navigate(filesHref(target)) }}>
                                  {item.name}
                                </a>
                              ) : (
                                <span className="truncate" title={item.contentType}>{item.name}</span>
                              )}
                            </div>
                          </TableCell>
                          <TableCell className="hidden text-sm text-muted-foreground tabular-nums sm:table-cell">
                            {item.kind === 'file' ? formatBytes(item.size) : '—'}
                          </TableCell>
                          <TableCell className="hidden text-sm text-muted-foreground md:table-cell">
                            {new Date(item.mtime).toLocaleString()}
                          </TableCell>
                          <TableCell>
                            <div className="flex justify-end gap-1">
                              {item.kind === 'file' ? (
                                <IconButton label={`Download ${item.name}`} disabled={disabled} onClick={() => void download(item)} busy={busy === `download:${item.name}`}>
                                  <Download className="size-4" aria-hidden />
                                </IconButton>
                              ) : null}
                              <IconButton label={`Open ${item.name} on the computer`} disabled={disabled} onClick={() => void openOnComputer(item)} busy={busy === `open:${item.name}`}>
                                <MonitorUp className="size-4" aria-hidden />
                              </IconButton>
                              <IconButton label={`Rename ${item.name}`} disabled={disabled} onClick={() => void rename(item)} busy={busy === `rename:${item.name}`}>
                                <Pencil className="size-4" aria-hidden />
                              </IconButton>
                              <IconButton label={`Move ${item.name} to the Trash`} disabled={disabled} onClick={() => void trash(item)} busy={busy === `trash:${item.name}`}>
                                <Trash2 className="size-4" aria-hidden />
                              </IconButton>
                            </div>
                          </TableCell>
                        </TableRow>
                      )
                    })}
                  </TableBody>
                </Table>
              )}
            </div>
          </DashboardPanel>
        ) : null}
      </div>
    </PageContainer>
  )
}

function SortHead({ label, active, dir, onClick, className }: { label: string; active: boolean; dir: 'asc' | 'desc'; onClick: () => void; className?: string }) {
  return (
    <TableHead className={className} aria-sort={active ? (dir === 'asc' ? 'ascending' : 'descending') : 'none'}>
      <button type="button" className="inline-flex items-center gap-1 hover:text-fg" onClick={onClick}>
        {label}{active ? <span aria-hidden>{dir === 'asc' ? '↑' : '↓'}</span> : null}
      </button>
    </TableHead>
  )
}

function IconButton({ label, disabled, busy, onClick, children }: { label: string; disabled: boolean; busy: boolean; onClick: () => void; children: React.ReactNode }) {
  return (
    <Button size="sm" variant="ghost" className="size-8 p-0" title={label} aria-label={label} disabled={disabled} onClick={onClick}>
      {busy ? <Spinner size={14} /> : children}
    </Button>
  )
}
