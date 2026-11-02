import { randomBytes } from 'node:crypto'

/**
 * How a computer's start is going, step by step, as the host does the work (docs/architecture.md,
 * "Starting a computer"). A boot begins when the computer starts waking (or when the boot
 * route starts it), each step is reported by the code doing it, and it ends when the computer
 * runs or fails. Nothing here is estimated: a step's `progress` is set only from real counts.
 */
export type BootStepId = 'image' | 'network' | 'disk' | 'start' | 'display'
export type BootStepState = 'pending' | 'active' | 'done' | 'skipped' | 'failed'
export interface BootStep {
  id: BootStepId
  label: string
  state: BootStepState
  detail: string | null
  progress: { completed: number; total: number | null } | null
}
export interface Boot {
  id: string
  state: 'running' | 'succeeded' | 'failed'
  startedAt: string
  finishedAt: string | null
  error: string | null
  steps: BootStep[]
}
export type BootUpdate = Partial<Pick<BootStep, 'detail' | 'progress'>>
/** What a controller calls as it reaches each step of a wake. */
export type BootReport = (step: BootStepId, update?: BootUpdate) => void

/** The steps each runtime takes, in the order it takes them. */
export const BOOT_STEPS: Record<'container' | 'microvm', BootStepId[]> = {
  // Docker creates the container and its home in one step; the network comes first.
  container: ['image', 'network', 'disk', 'start', 'display'],
  // appkit-desk makes the overlay disk as it starts the machine, so it is part of starting.
  microvm: ['image', 'network', 'start', 'display'],
}

const LABELS: Record<BootStepId, string> = {
  image: 'Downloading the system image',
  network: 'Setting up its network',
  disk: 'Making its disk',
  start: 'Starting it up',
  display: 'Opening its display',
}

export class BootProgress {
  private current: Boot | null = null
  private listeners = new Set<(boot: Boot) => void>()

  constructor(private readonly order: BootStepId[] = BOOT_STEPS.container, private readonly now: () => Date = () => new Date()) {}

  get(): Boot | null { return this.current && copy(this.current) }

  /** Called with every change, until unsubscribed. */
  subscribe(listener: (boot: Boot) => void): () => void {
    this.listeners.add(listener)
    return () => { this.listeners.delete(listener) }
  }

  /** Starts a boot, or returns the one under way. */
  begin(): Boot {
    if (this.current?.state !== 'running') {
      this.current = {
        id: randomBytes(6).toString('hex'), state: 'running', startedAt: this.now().toISOString(), finishedAt: null, error: null,
        steps: this.order.map(id => ({ id, label: LABELS[id], state: 'pending', detail: null, progress: null })),
      }
      this.publish()
    }
    return copy(this.current)
  }

  /**
   * A step is under way: steps before it that were under way are done, and ones never reached
   * were not needed. Reporting a step again updates its detail or progress. Reports outside a
   * boot, or for a step this runtime does not take, are ignored.
   */
  readonly report: BootReport = (id, update = {}) => {
    const boot = this.current
    if (boot?.state !== 'running') return
    const index = boot.steps.findIndex(step => step.id === id)
    if (index < 0) return
    boot.steps.forEach((step, i) => {
      if (i < index && step.state === 'active') finish(step)
      if (i < index && step.state === 'pending') step.state = 'skipped'
    })
    const step = boot.steps[index]!
    if (step.state === 'done' || step.state === 'skipped') step.progress = null
    step.state = 'active'
    if (update.detail !== undefined) step.detail = update.detail
    if (update.progress !== undefined) step.progress = update.progress
    this.publish()
  }

  /** The computer runs: the step under way is done and steps never reached were not needed. */
  succeed(): void {
    const boot = this.current
    if (boot?.state !== 'running') return
    for (const step of boot.steps) {
      if (step.state === 'active') finish(step)
      else if (step.state === 'pending') step.state = 'skipped'
    }
    boot.state = 'succeeded'
    boot.finishedAt = this.now().toISOString()
    this.publish()
  }

  /** The boot failed at the step under way (or the first not yet reached), for this reason. */
  fail(message: string): void {
    const boot = this.current
    if (boot?.state !== 'running') return
    const failed = boot.steps.find(step => step.state === 'active') ?? boot.steps.find(step => step.state === 'pending')
    if (failed) { failed.state = 'failed'; failed.progress = null }
    boot.state = 'failed'
    boot.error = message
    boot.finishedAt = this.now().toISOString()
    this.publish()
  }

  private publish(): void {
    const boot = this.current
    if (!boot) return
    for (const listener of this.listeners) listener(copy(boot))
  }
}

function finish(step: BootStep): void {
  step.state = 'done'
  if (step.progress?.total != null) step.progress = { completed: step.progress.total, total: step.progress.total }
}

function copy(boot: Boot): Boot {
  return { ...boot, steps: boot.steps.map(step => ({ ...step, progress: step.progress && { ...step.progress } })) }
}

/** A byte count for an owner: "1.2 GB". */
export function formatBytes(bytes: number): string {
  if (bytes < 1000) return `${bytes} B`
  const units = ['KB', 'MB', 'GB', 'TB']
  let value = bytes / 1000, unit = 0
  while (value >= 1000 && unit < units.length - 1) { value /= 1000; unit++ }
  return `${value >= 100 ? Math.round(value) : value.toFixed(1)} ${units[unit]}`
}
