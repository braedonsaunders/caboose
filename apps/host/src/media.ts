import { AgentUnavailableError, type AgentGuest } from './agents.js'

/**
 * Media handoff: the video playing in the computer's Chromium, offered to the phone so it
 * can play it natively. The guest's extension and native host (guest/media-handoff) keep
 * /home/caboose/.cache/caboose/media.json current; the host reads it about once a second,
 * but only while the computer is already running and a display client is connected. Reads
 * go straight to the guest: they never wake the computer, hold a lease or delay parking.
 * Commands go back through media-command.json. See docs/architecture.md § Media handoff.
 */
export type MediaKind = 'youtube' | 'hls' | 'video'

export interface MediaState {
  id: string
  page: string
  title: string
  src?: string
  kind: MediaKind
  videoId?: string
  /** Seconds; in what the host sends, extrapolated to `updatedAt` while playing. */
  position: number
  /** Seconds, or null for a live stream or a duration not yet known. */
  duration: number | null
  paused: boolean
  /** Milliseconds since the epoch: in what the host sends, the host-clock moment `position` describes. */
  updatedAt: number
}

export type MediaEvent =
  | { type: 'media.playing'; media: MediaState }
  | { type: 'media.stopped'; id: string }

export interface MediaCommand { id: string; action: 'pause' | 'play'; position?: number }

export const MEDIA_ID = /^[A-Za-z0-9._-]{1,64}$/
const VIDEO_ID = /^[A-Za-z0-9_-]{11}$/
const MAX_POSITION = 1e7
const NOW_MARKER = '\n__CABOOSE_NOW__'

/**
 * Prints the state file, but only while the native host that owns it is alive (a file left
 * by a browser that has gone, or from before a reboot, is not a playing video), then the
 * guest's clock, so a skewed guest clock cannot skew the extrapolated position.
 */
export const READ_SCRIPT = [
  'd=/home/caboose/.cache/caboose',
  'pid=$(cat "$d/media-host.pid" 2>/dev/null)',
  'case "$pid" in ""|*[!0-9]*) ;; *) grep -qs caboose-media-host "/proc/$pid/cmdline" && head -c 65536 "$d/media.json" 2>/dev/null ;; esac',
  `printf '${NOW_MARKER.replace('\n', '\\n')}%s' "$(date +%s%3N)"`,
].join('\n')

/** Atomically replaces media-command.json as user caboose; $1 is the command JSON. */
export const WRITE_SCRIPT = [
  'set -e',
  'umask 077',
  'd=/home/caboose/.cache/caboose',
  'mkdir -p "$d"',
  't=$(mktemp "$d/.media-command.XXXXXX")',
  `printf '%s' "$1" > "$t"`,
  'mv -f "$t" "$d/media-command.json"',
].join('\n')

function httpUrl(value: unknown, max = 4096): value is string {
  if (typeof value !== 'string' || value.length > max) return false
  try { return ['http:', 'https:'].includes(new URL(value).protocol) } catch { return false }
}

function seconds(value: unknown): value is number {
  return typeof value === 'number' && Number.isFinite(value) && value >= 0 && value <= MAX_POSITION
}

/** The guest's state file, checked field by field: the guest is not trusted to be well formed. */
export function parseMediaState(value: unknown): MediaState | null {
  if (!value || typeof value !== 'object' || Array.isArray(value)) return null
  const { id, page, title, src, kind, videoId, position, duration, paused, updatedAt } = value as Record<string, unknown>
  if (typeof id !== 'string' || !MEDIA_ID.test(id) || !httpUrl(page) || typeof paused !== 'boolean') return null
  if (kind !== 'youtube' && kind !== 'hls' && kind !== 'video') return null
  if (kind === 'youtube' ? typeof videoId !== 'string' || !VIDEO_ID.test(videoId) : videoId !== undefined || !httpUrl(src)) return null
  if (src !== undefined && !httpUrl(src)) return null
  if (!seconds(position) || !(duration === null || seconds(duration))) return null
  if (typeof updatedAt !== 'number' || !Number.isSafeInteger(updatedAt) || updatedAt < 0) return null
  return {
    id, page, title: typeof title === 'string' ? title.slice(0, 300) : '',
    ...(src !== undefined ? { src } : {}), kind, ...(kind === 'youtube' ? { videoId: videoId as string } : {}),
    position, duration, paused, updatedAt,
  }
}

/** Validates a control request; `rawId` is the URL path segment, not decoded. */
export function parseMediaCommand(rawId: string, input: Record<string, unknown>): MediaCommand {
  if (!MEDIA_ID.test(rawId)) throw new MediaInputError('media id must match /^[A-Za-z0-9._-]{1,64}$/')
  const unknown = Object.keys(input).filter(key => key !== 'action' && key !== 'position')
  if (unknown.length) throw new MediaInputError(`unknown field: ${unknown[0]}`)
  const { action, position } = input
  if (action !== 'pause' && action !== 'play') throw new MediaInputError('action must be "pause" or "play"')
  if (position === undefined) return { id: rawId, action }
  if (action !== 'play') throw new MediaInputError('position is only valid with "play"')
  if (!seconds(position)) throw new MediaInputError(`position must be a number of seconds from 0 to ${MAX_POSITION}`)
  return { id: rawId, action, position }
}

interface Observed { media: MediaState; raw: string; observedAt: number }

export class MediaHandoff {
  private observed: Observed | null = null
  private timer: ReturnType<typeof setInterval> | undefined
  private polling = false
  private seq = 0
  /** The first read after polling starts is announced even if unchanged: no client saw it. */
  private announce = false

  constructor(
    private readonly guest: () => AgentGuest | undefined,
    private readonly emit: (event: MediaEvent) => void,
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

  /** The current media while polling, its position extrapolated to now, or null. */
  watched(): MediaState | null { return this.active ? this.current() : null }

  /** The last media read, its position extrapolated to now, or null. */
  current(): MediaState | null {
    if (!this.observed) return null
    const { media, observedAt } = this.observed
    const now = this.now()
    let position = media.position + (media.paused ? 0 : Math.max(0, now - observedAt) / 1000)
    if (media.duration !== null && media.duration > 0) position = Math.min(position, media.duration)
    return { ...media, position: Math.round(position * 1000) / 1000, updatedAt: now }
  }

  /**
   * For GET /v1/media: null unless the computer is running; otherwise a fresh read when no
   * display client keeps the state polled. Never wakes or leases the computer.
   */
  async read(running: boolean): Promise<MediaState | null> {
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

  /** Writes a command for the guest's native host; the caller holds the computer running. */
  async send(command: MediaCommand): Promise<void> {
    const guest = this.guest()
    if (!guest) throw new AgentUnavailableError()
    // Milliseconds keep seq increasing across host restarts; the native host ignores any seq
    // it has already passed.
    this.seq = Math.max(this.now(), this.seq + 1)
    const body = JSON.stringify({ seq: this.seq, ...command })
    await guest.run('/usr/sbin/runuser', ['-u', 'caboose', '--', '/bin/sh', '-c', WRITE_SCRIPT, 'sh', body], 15_000)
  }

  private parse(output: string): Observed | null {
    const marker = output.lastIndexOf(NOW_MARKER)
    const text = (marker >= 0 ? output.slice(0, marker) : output).trim()
    if (!text) return null
    let media: MediaState | null
    try { media = parseMediaState(JSON.parse(text)) } catch { media = null }
    if (!media) return null
    const guestNow = marker >= 0 ? Number(output.slice(marker + NOW_MARKER.length).trim()) : Number.NaN
    // How long ago, by the guest's clock, the position was sampled, placed on the host's clock.
    const age = Number.isFinite(guestNow) ? Math.max(0, guestNow - media.updatedAt) : 0
    return { media, raw: JSON.stringify(media), observedAt: this.now() - age }
  }

  private apply(next: Observed | null, announce = false): void {
    const previous = this.observed
    if ((previous?.raw ?? '') === (next?.raw ?? '') && !announce) return
    this.observed = next
    if (previous && previous.media.id !== next?.media.id) this.emit({ type: 'media.stopped', id: previous.media.id })
    const media = this.current()
    if (media) this.emit({ type: 'media.playing', media })
  }
}

export class MediaInputError extends Error {}
