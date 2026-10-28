import * as React from 'react'
import { Alert, AlertDescription, AlertTitle, Button } from '@braedonsaunders/appkit-ui'
import { Sunrise } from 'lucide-react'
import type { CabooseClient } from '../api.js'
import { useComputerActions } from '../actions.js'
import { isTransitioning, stateLabel } from '../state.js'
import type { ComputerHandle } from '../useComputer.js'

/** Runs a callback now and every `ms` while the tab is visible, and again when it becomes visible. */
export function useVisibleInterval(callback: () => void, ms: number, enabled = true): void {
  const latest = React.useRef(callback)
  latest.current = callback
  React.useEffect(() => {
    if (!enabled) return
    const tick = () => { if (document.visibilityState === 'visible') latest.current() }
    const timer = window.setInterval(tick, ms)
    document.addEventListener('visibilitychange', tick)
    return () => {
      window.clearInterval(timer)
      document.removeEventListener('visibilitychange', tick)
    }
  }, [ms, enabled])
}

/** Says why a page cannot act while the computer is not running, with Wake where waking is possible. */
export function NotRunningNotice({ client, computer, children }: { client: CabooseClient; computer: ComputerHandle; children: React.ReactNode }) {
  const actions = useComputerActions(client, computer)
  const state = computer.status?.state
  if (!state || state === 'running') return null
  const moving = isTransitioning(state)
  return (
    <Alert variant={state === 'error' ? 'destructive' : 'info'}>
      <AlertTitle>{moving ? `${stateLabel(state)}…` : state === 'error' ? 'This computer needs attention' : 'This computer is parked'}</AlertTitle>
      <AlertDescription>
        <div className="flex flex-wrap items-center gap-3">
          <span className="min-w-0 flex-1">{children}</span>
          {!moving ? (
            <Button size="sm" onClick={actions.wake} disabled={actions.busy !== null}>
              <Sunrise className="size-4" aria-hidden />{actions.busy === 'wake' ? 'Waking…' : 'Wake'}
            </Button>
          ) : null}
        </div>
      </AlertDescription>
    </Alert>
  )
}

/** The top of a computer tab: what it is for, and the tab's own actions. */
export function TabIntro({ description, actions }: { description: React.ReactNode; actions?: React.ReactNode }) {
  return (
    <div className="flex flex-wrap items-start justify-between gap-3">
      <p className="min-w-0 max-w-2xl flex-1 text-sm text-fg-muted">{description}</p>
      {actions ? <div className="flex flex-wrap items-center gap-2">{actions}</div> : null}
    </div>
  )
}

/** An app icon from a data URL, or its initials on a tile when it has none. */
export function AppIcon({ src, name, size = 40 }: { src?: string | null; name: string; size?: number }) {
  if (src) return <img src={src} alt="" width={size} height={size} className="shrink-0 rounded-md object-contain" style={{ width: size, height: size }} />
  const initials = name.split(/\s+/).filter(Boolean).slice(0, 2).map(word => word[0]?.toUpperCase()).join('') || '?'
  return (
    <span
      aria-hidden
      className="inline-flex shrink-0 items-center justify-center rounded-md border border-border bg-bg-subtle font-semibold text-fg-muted"
      style={{ width: size, height: size, fontSize: Math.round(size * 0.38) }}
    >
      {initials}
    </span>
  )
}

export function errorMessage(failure: unknown): string {
  return failure instanceof Error ? failure.message : String(failure)
}
