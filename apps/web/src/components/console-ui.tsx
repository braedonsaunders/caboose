import type { ComponentProps, ReactNode } from 'react'
import { AnimatedNumber, PageHeader as AppKitPageHeader } from '@braedonsaunders/appkit-ui'
import { DashboardMetricCard as Metric, DashboardPanel as Panel } from '@braedonsaunders/appkit-dashboard/primitives'

/** Caboose's presentation of the shared AppKit primitives. */
export function PageHeader(props: ComponentProps<typeof AppKitPageHeader>) {
  return <AppKitPageHeader {...props} className={`console-page-header ${props.className ?? ''}`} />
}
export function DashboardMetricCard(props: ComponentProps<typeof Metric>) {
  return <Metric {...props} value={typeof props.value === 'number' ? <AnimatedNumber value={props.value} /> : props.value} className={`console-metric ${props.className ?? ''}`} />
}
export function DashboardPanel(props: ComponentProps<typeof Panel>) {
  return <Panel {...props} className={`console-panel ${props.className ?? ''}`} />
}

export function ResourceMeter({ label, value, total, detail }: { label: string; value: number; total?: number | null; detail: ReactNode }) {
  const percent = total && total > 0 ? value / total * 100 : null
  return <div className="space-y-2">
    <div className="flex flex-wrap items-baseline justify-between gap-2 text-sm"><span className="font-medium">{label}</span><span className="text-fg-muted tabular-nums">{detail}</span></div>
    {percent !== null ? <div className="console-meter" role="meter" aria-label={label} aria-valuemin={0} aria-valuemax={100} aria-valuenow={Math.min(100, Math.max(0, percent))} aria-valuetext={`${Math.round(percent)}%`}><span className={percent > 100 ? 'bg-warning' : 'bg-primary'} style={{ width: `${Math.min(100, Math.max(0, percent))}%` }} /></div> : null}
  </div>
}

export function MeasurementNotes({ children }: { children: ReactNode }) {
  return <details className="console-notes"><summary>About these measurements</summary><div className="space-y-2 pt-3 text-sm text-fg-muted">{children}</div></details>
}
