import { DashboardPanel } from '../../components/console-ui.js'
import { Archive, ShieldCheck } from 'lucide-react'
import * as React from 'react'
import { Alert, AlertDescription, AlertTitle, Badge, Button, EmptyState, Table, TableBody, TableCell, TableHead, TableHeader, TableRow, promptDialog } from '@braedonsaunders/appkit-ui'
import { CabooseApiError, type CabooseClient } from '../../api.js'
import type { RecoveryStatus } from '../../recovery.js'

export function Backups({ client, onUnauthorized }: { client: CabooseClient; onUnauthorized: () => void }) {
  const [status, setStatus] = React.useState<RecoveryStatus | null>(null)
  const [error, setError] = React.useState<string | null>(null)
  const [busy, setBusy] = React.useState(false)
  React.useEffect(() => {
    let active = true, pending = false
    const refresh = async () => {
      if (pending || document.visibilityState === 'hidden') return
      pending = true
      try { const value = await client.recovery(); if (active) { setStatus(value); setError(null) } }
      catch (failure) { if (active) { setStatus(null); if (failure instanceof CabooseApiError && failure.isUnauthorized) onUnauthorized(); else setError(failure instanceof Error ? failure.message : String(failure)) } }
      finally { pending = false }
    }
    void refresh()
    const timer = setInterval(() => void refresh(), 5000)
    return () => { active = false; clearInterval(timer) }
  }, [client, onUnauthorized])
  async function run(action: () => Promise<RecoveryStatus>) {
    setBusy(true); setError(null)
    try { setStatus(await action()) } catch (failure) { setError(failure instanceof Error ? failure.message : String(failure)) }
    finally { setBusy(false) }
  }
  async function restore(id: string, date: string) {
    const typed = await promptDialog({ title: 'Replace this computer’s disk?', label: `Restore the capture from ${new Date(date).toLocaleString()}. This closes apps, discards memory and all changes since this capture, and restarts the computer. Type RESTORE to continue.`, confirmLabel: 'Replace disk and restart' })
    if (typed !== 'RESTORE') return
    await run(() => client.restoreRecovery(id))
  }
  return <div className="space-y-6">
    <div className="flex flex-wrap items-start justify-between gap-4"><div><h2 className="text-lg font-semibold tracking-tight">Recovery captures</h2><p className="mt-1 text-sm text-fg-muted">Capture a parked disk or restore this computer to a previous capture.</p></div><Button disabled={busy || !status?.captureReady} onClick={() => void run(() => client.captureRecovery())}>{busy || status?.capturing ? 'Working…' : 'Capture parked disk'}</Button></div>
    {error ? <Alert variant="destructive"><AlertTitle>Recovery request failed</AlertTitle><AlertDescription>{error}</AlertDescription></Alert> : null}
    <Alert variant="info"><AlertTitle>Local recovery, on this host</AlertTitle><AlertDescription>Captures share this server’s storage and failure domain. Keep an independent server backup. Phone backups are encrypted with keys held by the person’s devices and cannot be read here.</AlertDescription></Alert>
    {!status ? <p role="status" className="text-sm text-fg-muted">{error ? 'Recovery status is unavailable.' : 'Loading recovery status…'}</p> : <>
      <div className="grid gap-4 sm:grid-cols-2">
        <DashboardPanel title="Capture readiness" icon={<ShieldCheck className="size-4" aria-hidden />}><Badge variant={status.captureReady ? 'success' : 'secondary'}>{status.captureReady ? 'Ready to capture' : 'Not ready'}</Badge><p className="mt-3 text-sm text-fg-muted">{status.reason ?? status.captureReason ?? 'Capture a coherent parked disk without waking the computer.'}</p>{status.lastOperation ? <p role="status" className="mt-3 text-sm">Last {status.lastOperation.kind}: {status.lastOperation.state}. {status.lastOperation.error}</p> : null}</DashboardPanel>
        <DashboardPanel title="Retention" icon={<Archive className="size-4" aria-hidden />}><p className="text-2xl font-semibold">{status.retention.newest} <span className="text-sm font-normal text-fg-muted">newest captures retained</span></p><p className="mt-3 text-sm text-fg-muted">Captures being downloaded by a phone are also retained. Deleting the computer deletes its local captures.</p></DashboardPanel>
      </div>
      <DashboardPanel title="Available captures">
        {status.captures.length === 0 ? <EmptyState icon={<Archive className="size-6" aria-hidden />} title="No captures yet" description="When this computer is ready, capture its parked disk using the action above." /> : <Table containerClassName="border-0 shadow-none"><TableHeader><TableRow><TableHead>Captured</TableHead><TableHead>Disk size</TableHead><TableHead><span className="sr-only">Actions</span></TableHead></TableRow></TableHeader><TableBody>{status.captures.map(capture => <TableRow key={capture.id}><TableCell className="font-medium">{new Date(capture.createdAt).toLocaleString()}</TableCell><TableCell className="tabular-nums">{(capture.diskBytes / 1024 ** 3).toFixed(1)} GiB</TableCell><TableCell className="text-right"><Button variant="outline" size="sm" disabled={busy || status.busy || status.capturing || status.restoring || !status.available} onClick={() => void restore(capture.id, capture.createdAt)}>Restore…</Button></TableCell></TableRow>)}</TableBody></Table>}
      </DashboardPanel>
    </>}
    <details className="rounded-xl border border-border bg-surface p-5"><summary className="cursor-pointer text-sm font-medium">Whole-server disaster recovery</summary><p className="mt-3 max-w-3xl text-sm leading-relaxed text-fg-muted">Preserve an offline copy of the state and identity database, disk and image dependencies, and protected configuration and secrets on independent storage. A local computer capture does not include these. Restore the server offline before starting computers.</p></details>
  </div>
}
