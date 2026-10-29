import { AgentUnavailableError, type AgentGuest } from './agents.js'

/**
 * Now playing: the MPRIS player the computer's caboose-bridge daemon shows, offered to the
 * phone's Now Playing. The daemon keeps /home/caboose/.cache/caboose/now-playing.json
 * current; the host reads it about once a second, but only while the computer is already
 * running and a display client is connected. Reads never wake the computer, hold a lease or
 * delay parking. Commands go back through now-playing-command.json. See
 * docs/native-bridge.md § Now playing.
 */
export interface NowPlayingState {
  id: string
  player: string
  title: string
  artist: string
  album: string
  artwork: string | null
  /** Seconds; in what the host sends, extrapolated to `updatedAt` while playing. */
  position: number
  duration: number | null
  paused: boolean
  rate: number
  canPlay: boolean
  canPause: boolean
  canNext: boolean
  canPrevious: boolean
  canSeek: boolean
  /** Milliseconds since the epoch: in what the host sends, the host-clock moment `position` describes. */
  updatedAt: number
}

export type NowPlayingEvent =
  | { type: 'now-playing.changed'; nowPlaying: NowPlayingState }
  | { type: 'now-playing.stopped'; id: string }

export type NowPlayingAction = 'play' | 'pause' | 'toggle' | 'next' | 'previous' | 'seek'
export type NowPlayingCommand = { id: string; action: Exclude<NowPlayingAction, 'seek'> } | { id: string; action: 'seek'; position: number }

export const NOW_PLAYING_ID = /^[A-Za-z0-9._-]{1,64}$/
const ACTIONS: readonly NowPlayingAction[] = ['play', 'pause', 'toggle', 'next', 'previous', 'seek']
const MAX_POSITION = 1e7
const NOW_MARKER = '\n__CABOOSE_NOW__'

/**
 * Prints the state file, but only while the bridge daemon that owns it is alive (a file left
 * from before a reboot is not a playing track), then the guest's clock, so a skewed guest
 * clock cannot skew the extrapolated position.
 */
export const READ_SCRIPT = [
  'd=/home/caboose/.cache/caboose',
  'pid=$(cat "$d/bridge/daemon.pid" 2>/dev/null)',
  'case "$pid" in ""|*[!0-9]*) ;; *) grep -qs caboose-bridge "/proc/$pid/cmdline" && head -c 65536 "$d/now-playing.json" 2>/dev/null ;; esac',
  `printf '${NOW_MARKER.replace('\n', '\\n')}%s' "$(date +%s%3N)"`,
].join('\n')

/** Atomically replaces now-playing-command.json as user caboose; $1 is the command JSON. */
export const WRITE_SCRIPT = [
  'set -e',
  'umask 077',
  'd=/home/caboose/.cache/caboose',
  'mkdir -p "$d"',
  't=$(mktemp "$d/.now-playing-command.XXXXXX")',
  `printf '%s' "$1" > "$t"`,
  'mv -f "$t" "$d/now-playing-command.json"',
].join('\n')

function seconds(value: unknown): value is number {
  return typeof value === 'number' && Number.isFinite(value) && value >= 0 && value <= MAX_POSITION
}

function bounded(value: unknown, max: number): value is string {
  return typeof value === 'string' && value.length <= max
}

function artwork(value: unknown): string | null {
  if (typeof value !== 'string' || value.length > 4096 || /[\x00-\x20\x7f]/.test(value)) return null
  try { return new URL(value).protocol === 'https:' ? value : null } catch { return null }
}

/** The daemon's state file, checked field by field: the guest is not trusted to be well formed. */
export function parseNowPlayingState(value: unknown): NowPlayingState | null {
  if (!value || typeof value !== 'object' || Array.isArray(value)) return null
  const v = value as Record<string, unknown>
  const { id, player, title, artist, album, position, duration, paused, rate, canPlay, canPause, canNext, canPrevious, canSeek, updatedAt } = v
  if (typeof id !== 'string' || !NOW_PLAYING_ID.test(id)) return null
  if (!bounded(player, 100) || !bounded(title, 300) || !bounded(artist, 300) || !bounded(album, 300)) return null
  if (!seconds(position) || !(duration === null || seconds(duration))) return null
  if (typeof rate !== 'number' || !Number.isFinite(rate) || rate < 0 || rate > 16) return null
  const flags = [paused, canPlay, canPause, canNext, canPrevious, canSeek]
  if (!flags.every(flag => typeof flag === 'boolean')) return null
  if (typeof updatedAt !== 'number' || !Number.isSafeInteger(updatedAt) || updatedAt < 0) return null
  return {
    id, player, title, artist, album, artwork: artwork(v.artwork), position, duration,
    paused: paused as boolean, rate,
    canPlay: canPlay as boolean, canPause: canPause as boolean, canNext: canNext as boolean,
    canPrevious: canPrevious as boolean, canSeek: canSeek as boolean, updatedAt,
  }
}

/** Validates a control request; `rawId` is the URL path segment, not decoded. */
export function parseNowPlayingCommand(rawId: string, input: Record<string, unknown>): NowPlayingCommand {
  if (!NOW_PLAYING_ID.test(rawId)) throw new NowPlayingInputError('now playing id must match /^[A-Za-z0-9._-]{1,64}$/')
  const unknown = Object.keys(input).find(key => key !== 'action' && key !== 'position')
  if (unknown !== undefined) throw new NowPlayingInputError(`unknown field: ${unknown}`)
  const { action, position } = input
  if (typeof action !== 'string' || !ACTIONS.includes(action as NowPlayingAction)) throw new NowPlayingInputError(`action must be one of ${ACTIONS.join(', ')}`)
  if (action === 'seek') {
    if (!seconds(position)) throw new NowPlayingInputError(`seek takes a position in seconds from 0 to ${MAX_POSITION}`)
    return { id: rawId, action, position }
  }
  if (position !== undefined) throw new NowPlayingInputError('position is only valid with "seek"')
  return { id: rawId, action: action as Exclude<NowPlayingAction, 'seek'> }
}

interface Observed { state: NowPlayingState; raw: string; observedAt: number }

export class NowPlaying {
  private observed: Observed | null = null
  private timer: ReturnType<typeof setInterval> | undefined
  private polling = false
  private seq = 0
  /** The first read after polling starts is announced even if unchanged: no client saw it. */
  private announce = false

  constructor(
    private readonly guest: () => AgentGuest | undefined,
    private readonly emit: (event: NowPlayingEvent) => void,
    private readonly pollMs = 1000,
    private readonly now: () => number = Date.now,
  ) {}

  /** Polling runs while `active`: the computer is running and a display client is connected. */
  setActive(active: boolean): void {
    if (active && !this.timer) {
      this.announce = true
      this.timer = setInterval(() => { void this.poll() }, this.pollMs)
      this.timer.unref()
      void this.poll()
    } else if (!active && this.timer) {
      clearInterval(this.timer)
      this.timer = undefined
    }
  }

  get active(): boolean { return this.timer !== undefined }

  /** The computer left the running state: nothing plays in a parked or restarting computer. */
  computerStopped(): void {
    this.setActive(false)
    this.apply(null)
  }

  /** The current track while polling, its position extrapolated to now, or null. */
  watched(): NowPlayingState | null { return this.active ? this.current() : null }

  /** The last track read, its position extrapolated to now, or null. */
  current(): NowPlayingState | null {
    if (!this.observed) return null
    const { state, observedAt } = this.observed
    const now = this.now()
    let position = state.position + (state.paused ? 0 : state.rate * Math.max(0, now - observedAt) / 1000)
    if (state.duration !== null && state.duration > 0) position = Math.min(position, state.duration)
    return { ...state, position: Math.round(position * 1000) / 1000, updatedAt: now }
  }

  /**
   * For GET /v1/now-playing: null unless the computer is running; otherwise a fresh read when
   * no display client keeps the state polled. Never wakes or leases the computer.
   */
  async read(running: boolean): Promise<NowPlayingState | null> {
    if (!running) return null
    if (!this.active) await this.poll()
    return this.current()
  }

  async poll(): Promise<void> {
    const guest = this.guest()
    if (this.polling || !guest) return
    this.polling = true
    try {
      const output = await guest.run('/bin/sh', ['-c', READ_SCRIPT], 10_000).catch(() => undefined)
      if (output !== undefined) {
        const announce = this.announce
        this.announce = false
        this.apply(this.parse(output), announce)
      }
    } finally {
      this.polling = false
    }
  }

  /** Writes a command for the guest's bridge daemon; the caller holds the computer running. */
  async send(command: NowPlayingCommand): Promise<void> {
    const guest = this.guest()
    if (!guest) throw new AgentUnavailableError()
    // Milliseconds keep seq increasing across host restarts; the daemon ignores any seq it
    // has already passed.
    this.seq = Math.max(this.now(), this.seq + 1)
    const body = JSON.stringify({ seq: this.seq, ...command })
    await guest.run('/usr/sbin/runuser', ['-u', 'caboose', '--', '/bin/sh', '-c', WRITE_SCRIPT, 'sh', body], 15_000)
  }

  private parse(output: string): Observed | null {
    const marker = output.lastIndexOf(NOW_MARKER)
    const text = (marker >= 0 ? output.slice(0, marker) : output).trim()
    if (!text) return null
    let state: NowPlayingState | null
    try { state = parseNowPlayingState(JSON.parse(text)) } catch { state = null }
    if (!state) return null
    const guestNow = marker >= 0 ? Number(output.slice(marker + NOW_MARKER.length).trim()) : Number.NaN
    // How long ago, by the guest's clock, the position was sampled, placed on the host's clock.
    const age = Number.isFinite(guestNow) ? Math.max(0, guestNow - state.updatedAt) : 0
    return { state, raw: JSON.stringify(state), observedAt: this.now() - age }
  }

  private apply(next: Observed | null, announce = false): void {
    const previous = this.observed
    if ((previous?.raw ?? '') === (next?.raw ?? '') && !announce) return
    this.observed = next
    if (previous && previous.state.id !== next?.state.id) this.emit({ type: 'now-playing.stopped', id: previous.state.id })
    const nowPlaying = this.current()
    if (nowPlaying) this.emit({ type: 'now-playing.changed', nowPlaying })
  }
}

export class NowPlayingInputError extends Error {}
