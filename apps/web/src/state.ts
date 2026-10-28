import type { ComputerState, ComputerStatus, TaskStatus } from './api.js'

export type Tone = 'success' | 'warning' | 'info' | 'destructive' | 'secondary'

export function stateLabel(state: ComputerState): string {
  switch (state) {
    case 'running': return 'Running'
    case 'parked': return 'Parked'
    case 'waking': return 'Waking'
    case 'parking': return 'Parking'
    case 'restarting': return 'Restarting'
    case 'error': return 'Needs attention'
  }
}

export function stateTone(state: ComputerState): Tone {
  switch (state) {
    case 'running': return 'success'
    case 'parked': return 'secondary'
    case 'error': return 'destructive'
    default: return 'info'
  }
}

/** A computer in motion: actions wait until it settles. */
export function isTransitioning(state: ComputerState): boolean {
  return state === 'waking' || state === 'parking' || state === 'restarting'
}

/** What the person can do from here, given what the host reports. */
export function availableActions(status: Pick<ComputerStatus, 'state' | 'capabilities'>): {
  wake: boolean
  park: boolean
  restart: boolean
} {
  const settled = !isTransitioning(status.state)
  return {
    wake: settled && (status.state === 'parked' || status.state === 'error'),
    park: status.state === 'running',
    restart: settled && status.capabilities.restart,
  }
}

export function taskTone(status: TaskStatus): Tone {
  switch (status) {
    case 'running': return 'info'
    case 'paused': return 'warning'
    case 'succeeded': return 'success'
    case 'failed': return 'destructive'
    case 'cancelled': return 'secondary'
  }
}

export function isLiveTask(status: TaskStatus): boolean {
  return status === 'running' || status === 'paused'
}

/** Whole-gigabyte steps within the host's bounds, plus the current value when it is not one. */
export function memoryChoices(min: number, max: number, current?: number): number[] {
  const steps = [512, 1024, 2048, 3072, 4096, 6144, 8192, 12288, 16384, 24576, 32768, 49152, 65536]
  const values = new Set(steps.filter(value => value >= min && value <= max))
  if (current !== undefined) values.add(current)
  return [...values].sort((a, b) => a - b)
}

export function idleChoices(min: number, max: number, current?: number): number[] {
  const minutes = [1, 5, 10, 15, 30, 60, 120, 240, 480, 1440]
  const values = new Set(minutes.map(value => value * 60_000).filter(value => value >= min && value <= max))
  if (current !== undefined) values.add(current)
  return [...values].sort((a, b) => a - b)
}
