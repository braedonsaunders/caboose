import { PageHeader, DashboardMetricCard, DashboardPanel, MeasurementNotes, ResourceMeter } from '../components/console-ui.js'
import * as React from 'react'

import { Alert, AlertDescription, Button, PageContainer, Table, TableBody, TableCell, TableHead, TableHeader, TableRow } from '@braedonsaunders/appkit-ui'
import { CabooseApiError, type CabooseClient } from '../api.js'
import { capacityValue, type Capacity as CapacityData, type Measurement } from '../capacity.js'

export interface CapacityProps { client: CabooseClient; onUnauthorized: () => void; tenantId?: string; tenantName?: string; scopeControl?: React.ReactNode }
/** Mount only for the selected authorized scope. Reads never wake computers or acquire leases. */
export function Capacity(props: CapacityProps) {
  // Key the inner view so a scope/client change cannot show a previous tenant's response.
  return <CapacityView key={props.tenantId ?? 'host'} {...props} />
}
function CapacityView({ client, onUnauthorized, tenantId, tenantName, scopeControl }: CapacityProps) {
  const [result, setResult] = React.useState<{ client: CabooseClient; value: CapacityData } | null>(null)
  const [error, setError] = React.useState<string | null>(null)
  const [refresh, setRefresh] = React.useState(0)
  const [loading, setLoading] = React.useState(false)
  const data = result?.client === client ? result.value : null
  React.useEffect(() => {
    let active = true, busy = false
    async function load() {
      if (busy || document.visibilityState === 'hidden') return
      busy = true
      setLoading(true)
      try { const value = await client.capacity(tenantId); if (active) { setResult({ client, value }); setError(null) } }
      catch (e) { if (active) { setResult(null); if (e instanceof CabooseApiError && e.isUnauthorized) onUnauthorized(); else setError(e instanceof Error ? e.message : 'Capacity could not be read') } }
      finally { busy = false; if (active) setLoading(false) }
    }
    void load()
    const timer = window.setInterval(() => void load(), 30_000)
    return () => { active = false; window.clearInterval(timer) }
  }, [client, tenantId, onUnauthorized, refresh])
  const number = (value: number | null): Measurement => ({ value, ...(value === null ? { reason: 'Active resources are unknown' } : {}) })
  return <PageContainer><div className="space-y-4">
    <PageHeader title={tenantId ? `${tenantName ?? 'Tenant'} usage` : 'Host capacity'} description="Resource allocations, measured capacity and storage." actions={<>{scopeControl}<Button variant="outline" disabled={loading} onClick={() => setRefresh(n => n + 1)}>{loading ? 'Refreshing…' : 'Refresh'}</Button></>} />
    {error && <Alert variant="destructive"><AlertDescription>{error}</AlertDescription></Alert>}
    {!data && !error && <p role="status">Reading capacity…</p>}
    {data && <>
      <p className="text-xs text-fg-muted">Sampled {new Date(data.sampledAt).toLocaleString()} · Refreshes every 30 seconds</p>
      {data.warnings.map(w => <Alert key={w} variant="warning"><AlertDescription>{w}</AlertDescription></Alert>)}
      <div className="grid grid-cols-2 gap-3 xl:grid-cols-4">
        <DashboardMetricCard label="Assigned memory" value={capacityValue(number(data.allocated.memoryBytes), 'bytes')} detail="All computer settings" />
        <DashboardMetricCard label="Running memory" value={capacityValue(number(data.running.memoryBytes), 'bytes')} detail="Running allocation" />
        <DashboardMetricCard label="Assigned vCPUs" value={capacityValue(number(data.allocated.vcpus))} detail="All computer settings" />
        <DashboardMetricCard label="Running vCPUs" value={capacityValue(number(data.running.vcpus))} detail="Running allocation" />
      </div>
      <div className="rounded-xl border border-border bg-surface px-4 py-3"><dl className="flex flex-wrap gap-x-5 gap-y-3">{Object.entries(data.counts).map(([name, value]) => <div key={name} className="flex items-baseline gap-2 text-sm"><dt className="capitalize text-fg-muted">{name === 'frozen' ? 'Sleeping' : name}</dt><dd className={`font-semibold tabular-nums ${name === 'error' && typeof value === 'number' && value > 0 ? 'text-danger' : ''}`}>{typeof value === 'number' ? value : capacityValue(value)}</dd></div>)}</dl><p className="mt-3 text-xs text-fg-muted">Configured allocations, not measured CPU or RAM use. Sleeping and transitioning computers may still hold memory.</p></div>
      {data.quotas && data.headroom && <DashboardPanel title="Quotas and headroom"><Table><TableHeader><TableRow><TableHead>Resource</TableHead><TableHead>Quota</TableHead><TableHead>Remaining</TableHead></TableRow></TableHeader><TableBody>{(['memoryBytes', 'vcpus', 'diskBytes'] as const).map(key => <TableRow key={key}><TableCell>{key === 'memoryBytes' ? 'Assigned memory' : key === 'vcpus' ? 'Assigned vCPUs' : 'Disk and parked memory blocks'}</TableCell><TableCell>{data.quotas![key] === null ? 'No quota' : capacityValue(number(data.quotas![key]), key === 'vcpus' ? 'count' : 'bytes')}</TableCell><TableCell>{capacityValue(data.headroom![key], key === 'vcpus' ? 'count' : 'bytes')}</TableCell></TableRow>)}</TableBody></Table><p className="mt-3 text-sm text-fg-muted">Negative headroom means the quota is exceeded. Backups are excluded from the existing disk quota. Headroom is not reserved capacity.</p></DashboardPanel>}
      <div className="grid items-start gap-4 xl:grid-cols-2"><DashboardPanel title="Storage"><Table><TableHeader><TableRow><TableHead>Category</TableHead><TableHead>Logical size</TableHead><TableHead>File blocks</TableHead></TableRow></TableHeader><TableBody>{(['disks', 'snapshots', 'backups'] as const).map(key => <TableRow key={key}><TableCell className="capitalize">{key}</TableCell><TableCell>{capacityValue(data.storage[key].logicalBytes, 'bytes')}</TableCell><TableCell>{capacityValue(data.storage[key].allocatedBytes, 'bytes')}</TableCell></TableRow>)}</TableBody></Table><MeasurementNotes><p>Sparse logical size is not disk consumption. Allocated file blocks may share reflink extents and must not be summed as unique physical usage. Snapshot totals cover the canonical local parked snapshot; remote cold archives and retained restore/template sources are excluded. Backups cover local captures and staging, not phone storage.</p><p className="text-sm text-fg-muted">Unique physical bytes: {capacityValue(data.storage.uniquePhysicalBytes, 'bytes')}</p><p>Storage samples may be up to 60 seconds old. Reading usage does not wake computers.</p></MeasurementNotes></DashboardPanel>
      {data.host && <DashboardPanel title="Host measurements"><div className="mb-4 space-y-4">{data.host.memoryTotalBytes.value !== null && data.host.memoryAvailableBytes.value !== null ? <ResourceMeter label="OS available memory" value={data.host.memoryAvailableBytes.value} total={data.host.memoryTotalBytes.value} detail={capacityValue(data.host.memoryAvailableBytes, 'bytes')} /> : null}{data.host.diskTotalBytes.value !== null && data.host.diskAvailableBytes.value !== null ? <ResourceMeter label="Image filesystem available" value={data.host.diskAvailableBytes.value} total={data.host.diskTotalBytes.value} detail={capacityValue(data.host.diskAvailableBytes, 'bytes')} /> : null}</div><dl className="divide-y divide-border text-sm">{([
        ['OS-visible memory', data.host.memoryTotalBytes, 'bytes'], ['OS free memory', data.host.memoryFreeBytes, 'bytes'], ['OS available memory', data.host.memoryAvailableBytes, 'bytes'],
        ['CPU busy time', data.host.cpuBusyPercent, 'percent'], ['CPU sample interval (ms)', data.host.cpuSampleMs, 'count'], ['OS-visible logical CPUs', data.host.logicalCpus, 'count'], ['Load average (1 minute)', data.host.loadAverage1m, 'count'],
        ['Image filesystem capacity', data.host.diskTotalBytes, 'bytes'], ['Image filesystem available', data.host.diskAvailableBytes, 'bytes'],
      ] as const).map(([label, value, unit]) => <div key={label} className="flex flex-wrap items-baseline justify-between gap-x-4 gap-y-1 py-2"><dt className="text-fg-muted">{label}</dt><dd className="font-medium text-right">{capacityValue(value, unit)}</dd></div>)}</dl><MeasurementNotes><p>CPU busy percentage uses elapsed CPU counters across all OS-visible CPUs, separate from assigned vCPUs. Load average is a scheduler load count, not a percentage. OS memory and CPU measurements may include other workloads and do not describe container cgroup limits. Available memory includes kernel-estimated reclaimable memory where supported; free memory does not. Filesystem availability uses blocks available to this process and includes all workloads on that filesystem.</p></MeasurementNotes></DashboardPanel>}
      </div>
    </>}
  </div></PageContainer>
}
