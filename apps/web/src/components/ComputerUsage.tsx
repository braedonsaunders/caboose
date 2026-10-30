import * as React from 'react'
import { Button } from '@braedonsaunders/appkit-ui'
import type { ComputerUsage, ComputerStorage, Capacity } from '../../../../packages/capacity/types.js'
import type { CabooseClient } from '../api.js'
import { DashboardMetricCard, DashboardPanel, MeasurementNotes } from './console-ui.js'
import { capacityValue } from '../capacity.js'

const bytes = (value: number | null) => capacityValue({ value }, 'bytes')
export function cpuHistoryLabel(usage: ComputerUsage): string {
  return usage.coveredSeconds30d > 0 ? `${usage.cpuSeconds30d.toLocaleString(undefined, { maximumFractionDigits: 1 })} CPU seconds` : 'Collecting samples'
}
export function UsageMetrics({ usage }: { usage: ComputerUsage }) {
  return <><div className="grid gap-3 sm:grid-cols-2 xl:grid-cols-4">
    <DashboardMetricCard label={usage.memoryKind === 'resident' ? 'Resident RAM' : 'Memory charged'} value={bytes(usage.memoryBytes)} detail={`Runtime limit: ${bytes(usage.memoryLimitBytes)}`} />
    <DashboardMetricCard label="Inactive file cache" value={bytes(usage.cacheBytes)} detail="Included in charged memory; potentially reclaimable" />
    <DashboardMetricCard label="CPU activity" value={capacityValue({ value: usage.cpuPercent }, 'percent')} detail="100% = all runtime vCPUs busy" />
    <DashboardMetricCard label="CPU time · last 30 days" value={cpuHistoryLabel(usage)} detail={`${(usage.coveredSeconds30d / 3600).toFixed(1)} hours of measured coverage`} />
  </div><MeasurementNotes>
    <p>{usage.collectingSince ? `Collecting since ${new Date(usage.collectingSince).toLocaleString()}.` : 'Collection has not started.'} Missing intervals are excluded, never estimated. CPU seconds sum time across cores; they are not elapsed hours.</p>
    <p>Container memory includes cache and kernel charges. Resident RAM can include shared pages; neither value measures unique physical RAM. Provisioned limits are separate from consumption.</p>
    <p>{usage.sampledAt ? `Runtime sample: ${new Date(usage.sampledAt).toLocaleString()}.` : ''} {usage.reason}</p>
  </MeasurementNotes></>
}
export function ComputerUsagePanel({ client, id }: { client: CabooseClient; id: string }) {
  const [usage, setUsage] = React.useState<ComputerUsage | null>(null)
  const [storage, setStorage] = React.useState<ComputerStorage | { sampledAt: number; vm: Capacity['storage'] } | null>(null)
  const [error, setError] = React.useState('')
  const [busy, setBusy] = React.useState(false)
  const generation = React.useRef(0)
  React.useEffect(() => {
    const version = ++generation.current
    let active = true, loading = false
    setUsage(null); setStorage(null); setError(''); setBusy(false)
    const load = async () => {
      if (loading || document.visibilityState === 'hidden') return
      loading = true
      try { const value = await client.computerUsage(id); if (active) { setUsage(value); setError('') } }
      catch { if (active) { setUsage(null); setError('Usage could not be read') } }
      finally { loading = false }
    }
    void load(); const timer = window.setInterval(() => void load(), 30_000)
    return () => { active = false; if (generation.current === version) generation.current++; clearInterval(timer) }
  }, [client, id])
  async function measureStorage() {
    const version = generation.current
    setBusy(true); setError('')
    try { const value = await client.computerStorage(id); if (generation.current === version) setStorage(value) }
    catch { if (generation.current === version) { setStorage(null); setError('Storage measurement failed or another measurement is in progress') } }
    finally { if (generation.current === version) setBusy(false) }
  }
  return <DashboardPanel title="Measured usage">
    {usage ? <UsageMetrics usage={usage} /> : <p>Waiting for usage measurements…</p>}
    {error && <p role="alert">{error}</p>}
    <div className="mt-4"><Button variant="outline" disabled={busy} onClick={() => void measureStorage()}>{busy ? 'Measuring storage…' : 'Measure storage'}</Button></div>
    {storage && <div className="mt-4 space-y-2 text-sm">
      <p>Measured {new Date(storage.sampledAt).toLocaleString()}</p>
      {'vm' in storage ? <p>Disk allocated file blocks: {capacityValue(storage.vm.disks.allocatedBytes, 'bytes')} · Virtual capacity: {capacityValue(storage.vm.disks.logicalBytes, 'bytes')}</p> : <>
        <p>Home allocated file blocks: {capacityValue(storage.home.allocatedBytes, 'bytes')} · Logical files: {capacityValue(storage.home.logicalBytes, 'bytes')}</p>
        <p>Writable layer logical size: {capacityValue(storage.writableLayerLogicalBytes, 'bytes')}</p>
        <p>Shared image logical size: {capacityValue(storage.sharedImageLogicalBytes, 'bytes')}</p>
      </>}
    </div>}
    <MeasurementNotes><p>Storage is measured only on request and cached for 15 minutes for containers. Home file blocks can include shared reflink extents. Docker layer sizes are logical bytes, not allocated physical blocks. Shared images are not a per-computer physical cost. Unique physical usage is unavailable. No measurement wakes the computer.</p></MeasurementNotes>
  </DashboardPanel>
}
