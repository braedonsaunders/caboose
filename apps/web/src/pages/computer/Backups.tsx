import * as React from 'react'
import { Alert, AlertDescription, AlertTitle, Button, SettingsSection, promptDialog } from '@braedonsaunders/appkit-ui'
import type { CabooseClient } from '../../api.js'
import type { RecoveryStatus } from '../../recovery.js'

export function Backups({ client }: { client: CabooseClient }) {
  const [status, setStatus] = React.useState<RecoveryStatus | null>(null)
  const [error, setError] = React.useState<string | null>(null)
  const [busy, setBusy] = React.useState(false)
  React.useEffect(() => {
    let active = true
    const refresh = () => client.recovery().then(value => { if (active) setStatus(value) }).catch(failure => { if (active) setError(String(failure.message ?? failure)) })
    void refresh()
    const timer = setInterval(() => void refresh(), 5000)
    return () => { active = false; clearInterval(timer) }
  }, [client])
  async function run(action: () => Promise<RecoveryStatus>) {
    setBusy(true); setError(null)
    try { setStatus(await action()) } catch (failure) { setError(failure instanceof Error ? failure.message : String(failure)) }
    finally { setBusy(false) }
  }
  async function restore(id: string, date: string) {
    const typed = await promptDialog({ title: 'Replace this computer’s disk?', description: `Restore the capture from ${new Date(date).toLocaleString()}. This closes apps, discards memory and all changes since this capture, and restarts the computer. Type RESTORE to continue.`, confirmLabel: 'Replace disk and restart' })
    if (typed !== 'RESTORE') return
    await run(() => client.restoreRecovery(id))
  }
  return <div className="space-y-6">
    <SettingsSection title="Host recovery captures" description="Local captures share this server’s storage and failure domain. They are not an independent server backup. Phone backups remain encrypted with keys held by the person’s devices; this console cannot read them.">
      {error ? <Alert variant="destructive"><AlertTitle>Recovery request failed</AlertTitle><AlertDescription>{error}</AlertDescription></Alert> : null}
      {!status ? <p>Loading recovery status…</p> : <div className="space-y-4">
        <p>{status.reason ?? status.captureReason ?? 'Capture a coherent parked disk without waking the computer.'}</p>
        <p>Retention: newest {status.retention.newest} captures, plus captures a phone is downloading. Deleting the computer deletes its local captures.</p>
        <Button disabled={busy || !status.captureReady} onClick={() => void run(() => client.captureRecovery())}>{busy || status.capturing ? 'Working…' : 'Capture parked disk'}</Button>
        {status.lastOperation ? <p role="status">Last {status.lastOperation.kind}: {status.lastOperation.state}. {status.lastOperation.error}</p> : null}
        {status.captures.length === 0 ? <p>No host captures are available.</p> : status.captures.map(capture => <div key={capture.id} className="flex items-center justify-between gap-4 border-t py-3"><span>{new Date(capture.createdAt).toLocaleString()} · {(capture.diskBytes / 1024 ** 3).toFixed(1)} GiB disk</span><Button variant="outline" disabled={busy || status.busy || status.capturing || status.restoring || !status.available} onClick={() => void restore(capture.id, capture.createdAt)}>Restore…</Button></div>)}
      </div>}
    </SettingsSection>
    <SettingsSection title="Whole-server disaster recovery" description="The operator must preserve an offline copy of the state and identity database, disk and image dependencies, and protected configuration and secrets on independent storage. A local computer capture does not include these. Restore the server offline before starting computers.">{null}</SettingsSection>
  </div>
}
