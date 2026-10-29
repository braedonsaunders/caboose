import { spawn } from 'node:child_process'
import { randomBytes } from 'node:crypto'
import { mkdir, readFile, rename, writeFile } from 'node:fs/promises'
import { dirname } from 'node:path'

/**
 * Runs depot-builder.py in the host's trusted builder with the depot writable, passing each
 * JSON line it prints to `onEvent`. The builder never runs inside an owner's computer.
 */
export type DepotRunner = (args: string[], onEvent: (event: Record<string, unknown>) => void, timeoutMs: number) => Promise<void>
export interface DepotProgress { message: string; downloadedBytes?: number; totalBytes?: number }

const RUNTIME = /^[A-Za-z_][A-Za-z0-9_.-]{0,254}\/(x86_64|aarch64)\/[A-Za-z0-9_.-]{1,64}$/
const MAINTAIN_MS = 24 * 3600_000

/** "org.gnome.Platform/x86_64/49" → "GNOME 49", for progress a person reads. */
export function runtimeLabel(ref: string): string {
  const [id = ref, , branch = ''] = ref.split('/')
  const names: Record<string, string> = { 'org.gnome.Platform': 'GNOME', 'org.kde.Platform': 'KDE', 'org.freedesktop.Platform': 'Freedesktop', 'org.gnome.Sdk': 'GNOME SDK', 'org.kde.Sdk': 'KDE SDK', 'org.freedesktop.Sdk': 'Freedesktop SDK', 'io.elementary.Platform': 'elementary', 'org.winehq.Wine': 'Wine' }
  return `${names[id] ?? id.split('.').slice(-2).join(' ')} ${branch}`.trim()
}

interface State { usage: Record<string, Record<string, number>>; maintainedAt: number; runtimes: string[]; bytes: number | null }

/**
 * The host's shared Flatpak runtimes. Each runtime is downloaded once, when the first app
 * that needs it is installed, into one installation every computer mounts read-only. Apps
 * install into each computer and run on these runtimes in place of their own copies.
 * Runtimes update daily; a superseded one stays deployed for apps still running on it, and
 * one no computer reports using is removed.
 */
export class RuntimeDepot {
  private queue: Promise<unknown> = Promise.resolve()
  private ensuring = new Map<string, Promise<void>>()
  private state: State = { usage: {}, maintainedAt: 0, runtimes: [], bytes: null }
  private loaded: Promise<void> | undefined
  private maintaining: Promise<void> | undefined
  private saving: Promise<void> = Promise.resolve()
  constructor(private readonly runner: DepotRunner | null, private readonly file: string, private readonly now: () => number = Date.now) {}
  get enabled(): boolean { return this.runner !== null }
  private load(): Promise<void> {
    this.loaded ??= readFile(this.file, 'utf8').then(text => {
      const raw = JSON.parse(text) as Partial<State>
      const usage: State['usage'] = {}
      for (const [computer, refs] of Object.entries(raw.usage ?? {})) {
        if (!/^[A-Za-z0-9_-]{1,100}$/.test(computer) || !refs || typeof refs !== 'object') continue
        usage[computer] = Object.fromEntries(Object.entries(refs).filter(([ref, at]) => RUNTIME.test(ref) && Number.isSafeInteger(at)))
      }
      this.state = { usage, maintainedAt: Number.isSafeInteger(raw.maintainedAt) ? raw.maintainedAt! : 0, runtimes: Array.isArray(raw.runtimes) ? raw.runtimes.filter(ref => typeof ref === 'string' && RUNTIME.test(ref)) : [], bytes: Number.isSafeInteger(raw.bytes) ? raw.bytes! : null }
    }).catch(error => {
      if ((error as NodeJS.ErrnoException).code !== 'ENOENT') throw error
    })
    return this.loaded
  }
  /** Writes run one after another, each of the state as it is then, so none is lost or torn. */
  private save(): Promise<void> {
    const next = this.saving.then(async () => {
      await mkdir(dirname(this.file), { recursive: true })
      await writeFile(this.file + '.tmp', JSON.stringify(this.state))
      await rename(this.file + '.tmp', this.file)
    })
    this.saving = next.catch(() => {})
    return next
  }
  /** One builder at a time; each run is independent of the last one's failure. */
  private run(args: string[], onEvent: (event: Record<string, unknown>) => void, timeoutMs: number): Promise<void> {
    const runner = this.runner
    if (!runner) return Promise.reject(new Error('This host does not share runtimes'))
    const next = this.queue.then(() => runner(args, event => {
      if (event.type === 'state' && Array.isArray(event.runtimes)) {
        this.state.runtimes = event.runtimes.filter((ref): ref is string => typeof ref === 'string' && RUNTIME.test(ref))
        this.state.bytes = Number.isSafeInteger(event.bytes) ? event.bytes as number : this.state.bytes
      }
      onEvent(event)
    }, timeoutMs))
    this.queue = next.catch(() => {})
    return next.finally(() => this.save().catch(error => console.error('Cannot save depot state:', error)))
  }
  /** Adds a runtime (with its GL driver and locale extensions) unless the depot has it. */
  ensure(runtime: string, onProgress: (progress: DepotProgress) => void = () => {}): Promise<void> {
    if (!RUNTIME.test(runtime)) return Promise.reject(new Error('Invalid runtime'))
    let pending = this.ensuring.get(runtime)
    if (!pending) {
      const label = runtimeLabel(runtime)
      pending = this.load().then(() => this.run(['ensure', JSON.stringify(runtime)], event => {
        if (event.type === 'progress' && Number.isSafeInteger(event.downloaded) && Number.isSafeInteger(event.size) && (event.size as number) > 0)
          onProgress({ message: `Downloading ${label} for every computer on this host`, downloadedBytes: event.downloaded as number, totalBytes: event.size as number })
        else if (event.type === 'ready') onProgress({ message: `Adding ${label} to this host's shared runtimes` })
      }, 60 * 60_000)).finally(() => this.ensuring.delete(runtime))
      this.ensuring.set(runtime, pending)
    }
    return pending
  }
  /** Whether the depot had the runtime when the builder last reported. */
  has(runtime: string): boolean { return this.state.runtimes.includes(runtime) }
  /** Records the runtimes a computer's installed apps use, so collection keeps them. */
  async note(computer: string, runtimes: string[]): Promise<void> {
    await this.load()
    const at = this.now()
    const refs = this.state.usage[computer] ?? {}
    const next = Object.fromEntries(runtimes.filter(ref => RUNTIME.test(ref)).map(ref => [ref, at]))
    // Only a change, or a day's age, is worth a write.
    if (Object.keys(next).length === Object.keys(refs).length && Object.entries(next).every(([ref]) => refs[ref] !== undefined && at - refs[ref]! < 86400_000)) return
    this.state.usage[computer] = next
    await this.save()
  }
  async forget(computer: string): Promise<void> {
    await this.load()
    delete this.state.usage[computer]
    await this.save()
  }
  /** Daily: update every runtime, then remove the ones no computer reports using. */
  maintain(force = false): Promise<void> {
    this.maintaining ??= (async () => {
      await this.load()
      if (!this.enabled || (!force && this.now() - this.state.maintainedAt < MAINTAIN_MS)) return
      this.state.maintainedAt = this.now()
      await this.run(['update'], () => {}, 2 * 3600_000)
      const keep = [...new Set(Object.values(this.state.usage).flatMap(refs => Object.keys(refs)))]
      await this.run(['collect', JSON.stringify(keep)], () => {}, 30 * 60_000)
    })().finally(() => { this.maintaining = undefined })
    return this.maintaining
  }
  async status(): Promise<{ enabled: boolean; runtimes: string[]; bytes: number | null }> {
    await this.load()
    return { enabled: this.enabled, runtimes: [...this.state.runtimes], bytes: this.state.bytes }
  }
}

/** Parses a builder's output into events; anything that is not a JSON object is ignored. */
export function lines(onEvent: (event: Record<string, unknown>) => void): (chunk: Buffer) => void {
  let buffer = ''
  return chunk => {
    buffer += chunk.toString('utf8')
    if (buffer.length > 1_000_000) buffer = buffer.slice(-100_000)
    let index
    while ((index = buffer.indexOf('\n')) >= 0) {
      const line = buffer.slice(0, index); buffer = buffer.slice(index + 1)
      try { const event = JSON.parse(line) as unknown; if (event && typeof event === 'object' && !Array.isArray(event)) onEvent(event as Record<string, unknown>) } catch { /* not an event */ }
    }
  }
}

/**
 * The container runtime's builder: a throwaway container from the computer image, with the
 * depot volume writable. Computers mount the same volume read-only.
 */
export function containerDepotRunner(options: { image: string; volume: string; script: () => Promise<string>; securityArgs: string[]; docker?: string }): DepotRunner {
  return async (args, onEvent, timeoutMs) => {
    const script = await options.script()
    const name = `caboose-depot-${randomBytes(4).toString('hex')}`
    await new Promise<void>((resolve, reject) => {
      const child = spawn(options.docker ?? 'docker', ['run', '--rm', '--name', name, '--init', '-v', `${options.volume}:/depot`, ...options.securityArgs,
        '--entrypoint', '/usr/bin/python3', options.image, '-c', script, '/depot', ...args], { stdio: ['ignore', 'pipe', 'pipe'] })
      let stderr = ''
      child.stdout.on('data', lines(onEvent))
      child.stderr.on('data', chunk => { stderr = (stderr + chunk.toString('utf8')).slice(-4000) })
      const timer = setTimeout(() => { spawn(options.docker ?? 'docker', ['rm', '-f', name], { stdio: 'ignore' }); reject(new Error('The runtime builder timed out')) }, timeoutMs)
      timer.unref()
      child.on('error', error => { clearTimeout(timer); reject(error) })
      child.on('close', code => {
        clearTimeout(timer)
        if (code === 0) resolve()
        else reject(new Error(stderr.trim().split('\n').slice(-6).join('\n') || `The runtime builder failed (${code})`))
      })
    })
  }
}
