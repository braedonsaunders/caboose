import { AgentNotFoundError, AgentOperationError, AgentUnavailableError, type AgentGuest } from './agents.js'

/**
 * The native bridge's host side: file chooser requests from the guest's portal relayed to
 * the phone and answered from it (and `caboose-scan`'s scans), the phone's appearance, and the phone's location for
 * GeoClue. The guest is owner-controlled but may produce malformed data, so everything it
 * prints is validated field by field; everything the phone sends is validated strictly.
 * See docs/native-bridge.md.
 */
export type BridgeRequestType = 'file.open' | 'file.save' | 'scan'

export interface BridgeFilter { name: string; patterns: string[]; mimeTypes: string[] }

export interface BridgeRequest {
  id: string
  type: BridgeRequestType
  app: string
  title: string
  acceptLabel: string
  multiple: boolean
  directory: boolean
  filters: BridgeFilter[]
  currentFilter: number | null
  currentName: string
  currentFolder: string
  created: number
}

export type BridgeAnswer =
  | { id: string; response: 'ok'; paths: string[]; filter: number | null }
  | { id: string; response: 'cancel' }
  | { id: string; response: 'computer' }

export interface Appearance {
  colorScheme: 'light' | 'dark'
  accent: string
  contrast: 'normal' | 'high'
  reducedMotion: boolean
  textScale: number
}

export interface SharedLocation { latitude: number; longitude: number; accuracy: number; altitude: number | null }

export type BridgeEvent = { type: 'bridge.request'; request: BridgeRequest } | { type: 'bridge.cancel'; id: string }

/** What an answer is checked against: the request as it was delivered. */
interface Outstanding { type: BridgeRequestType; multiple: boolean; directory: boolean; filters: number; deliveredAt: number }

export const BRIDGE_ID = /^[0-9a-f]{32}$/
const HOME = '/home/caboose'
const CONTROL = /\p{Cc}/u
const MIME = /^[A-Za-z0-9!#$&^_.+-]{1,127}\/(?:\*|[A-Za-z0-9!#$&^_.+-]{1,127})$/
const MAX_LIST = 32
const MAX_DRAIN = 16
const MAX_PATHS = 64
const MAX_PATH_BYTES = 4096
/** The paths of one answer together, so the answer fits one guest command argument. */
export const MAX_ANSWER_PATH_CHARACTERS = 60_000
export const OUTSTANDING_MS = 24 * 60 * 60 * 1000
export const LOCATION_INTERVAL_MS = 5000
export const LOCATION_EXPIRY_MS = 30 * 60 * 1000
export const GEOLOCATION_FILE = '/etc/geolocation'
/** GeoClue's GCLUE_LOCATION_ALTITUDE_UNKNOWN (-G_MAXDOUBLE): its static source requires an altitude line. */
const ALTITUDE_UNKNOWN = String(-Number.MAX_VALUE)

const RUN = '/usr/sbin/runuser'
const BRIDGE = '/usr/local/bin/caboose-bridge'
function bridgeCommand(guest: AgentGuest, args: string[], timeoutMs = 15_000): Promise<string> {
  return guest.run(RUN, ['-u', 'caboose', '--', BRIDGE, ...args], timeoutMs)
}

function record(value: unknown): Record<string, unknown> | null {
  return value && typeof value === 'object' && !Array.isArray(value) ? value as Record<string, unknown> : null
}

function text(value: unknown, max: number): value is string {
  return typeof value === 'string' && value.length <= max && !CONTROL.test(value)
}

function list(value: unknown, item: (entry: unknown) => boolean): value is string[] {
  return Array.isArray(value) && value.length <= MAX_LIST && value.every(item)
}

/** `/home/caboose` followed by one or more non-empty segments that are not `.` or `..`. */
function homePath(value: unknown, allowHome: boolean): value is string {
  if (typeof value !== 'string' || CONTROL.test(value) || Buffer.byteLength(value) > MAX_PATH_BYTES) return false
  if (value === HOME) return allowHome
  if (!value.startsWith(`${HOME}/`)) return false
  return value.slice(HOME.length + 1).split('/').every(part => part !== '' && part !== '.' && part !== '..')
}

function index(value: unknown, length: number): value is number {
  return Number.isSafeInteger(value) && (value as number) >= 0 && (value as number) < length
}

function parseFilter(value: unknown): BridgeFilter | null {
  const filter = record(value)
  if (!filter) return null
  const { name, patterns, mimeTypes } = filter
  if (!text(name, 100)) return null
  if (!list(patterns, entry => text(entry, 255) && entry !== '')) return null
  if (!list(mimeTypes, entry => typeof entry === 'string' && MIME.test(entry))) return null
  return { name, patterns: [...patterns], mimeTypes: [...mimeTypes] }
}

/** The formats a `scan` request may ask for, each as its only filter: one PDF, or JPEG pages. */
export const SCAN_FORMATS: readonly { filter: BridgeFilter; multiple: boolean }[] = [
  { filter: { name: 'PDF', patterns: ['*.pdf'], mimeTypes: ['application/pdf'] }, multiple: false },
  { filter: { name: 'JPEG', patterns: ['*.jpg', '*.jpeg'], mimeTypes: ['image/jpeg'] }, multiple: true },
]

function sameFilter(a: BridgeFilter, b: BridgeFilter): boolean {
  const same = (x: string[], y: string[]) => x.length === y.length && x.every((entry, n) => entry === y[n])
  return a.name === b.name && same(a.patterns, b.patterns) && same(a.mimeTypes, b.mimeTypes)
}

/** A request printed by `caboose-bridge drain`, or null when any field is malformed. */
export function parseBridgeRequest(value: unknown): BridgeRequest | null {
  const r = record(value)
  if (!r) return null
  const { id, type, app, title, acceptLabel, multiple, directory, filters, currentFilter, currentName, currentFolder, created } = r
  if (typeof id !== 'string' || !BRIDGE_ID.test(id)) return null
  if (type !== 'file.open' && type !== 'file.save' && type !== 'scan') return null
  if (!text(app, 200) || !text(title, 200) || !text(acceptLabel, 64)) return null
  if (typeof multiple !== 'boolean' || typeof directory !== 'boolean') return null
  if (type === 'file.save' && (multiple || directory)) return null
  if (!Array.isArray(filters) || filters.length > MAX_LIST) return null
  const parsed: BridgeFilter[] = []
  for (const entry of filters) {
    const filter = parseFilter(entry)
    if (!filter) return null
    parsed.push(filter)
  }
  if (currentFilter !== null && !index(currentFilter, parsed.length)) return null
  if (typeof currentName !== 'string' || CONTROL.test(currentName) || Buffer.byteLength(currentName) > 255) return null
  if (type === 'file.save' ? currentName.includes('/') || currentName === '.' || currentName === '..' : currentName !== '') return null
  if (currentFolder !== '' && !homePath(currentFolder, true)) return null
  // A scan names its format as its one filter, and nothing about a folder.
  if (type === 'scan') {
    if (directory || currentFolder !== '' || parsed.length !== 1 || currentFilter !== 0) return null
    if (!SCAN_FORMATS.some(format => format.multiple === multiple && sameFilter(format.filter, parsed[0]!))) return null
  }
  if (!Number.isSafeInteger(created) || (created as number) < 0) return null
  return {
    id, type, app, title, acceptLabel, multiple, directory, filters: parsed,
    currentFilter: currentFilter as number | null, currentName, currentFolder: currentFolder as string, created: created as number,
  }
}

function only(input: Record<string, unknown>, allowed: string[]): void {
  const unknown = Object.keys(input).find(key => !allowed.includes(key))
  if (unknown !== undefined) throw new BridgeInputError(`unknown field: ${unknown}`)
}

/** The phone's answer to a delivered request, checked against that request (400 when invalid). */
export function parseBridgeAnswer(id: string, input: Record<string, unknown>, request: Pick<Outstanding, 'type' | 'multiple' | 'filters'>): BridgeAnswer {
  const { response } = input
  if (response === 'cancel' || response === 'computer') {
    only(input, ['response'])
    return { id, response }
  }
  if (response !== 'ok') throw new BridgeInputError('response must be "ok", "cancel" or "computer"')
  only(input, ['response', 'paths', 'filter'])
  const { paths, filter } = input
  if (!Array.isArray(paths) || paths.length < 1 || paths.length > MAX_PATHS) throw new BridgeInputError(`paths must list 1 to ${MAX_PATHS} paths`)
  for (const path of paths) {
    if (!homePath(path, false)) throw new BridgeInputError(`each path must be an absolute path under ${HOME}/ of at most ${MAX_PATH_BYTES} bytes, without empty, . or .. segments or control characters`)
  }
  if (new Set(paths).size !== paths.length) throw new BridgeInputError('paths must be distinct')
  if ((paths as string[]).reduce((sum, path) => sum + path.length, 0) > MAX_ANSWER_PATH_CHARACTERS) throw new BridgeInputError(`paths must total at most ${MAX_ANSWER_PATH_CHARACTERS} characters`)
  if ((request.type === 'file.save' || !request.multiple) && paths.length !== 1) throw new BridgeInputError('this request takes exactly one path')
  if (filter !== undefined && filter !== null && !index(filter, request.filters)) throw new BridgeInputError('filter must be null or an index into the request\'s filters')
  return { id, response: 'ok', paths: [...paths as string[]], filter: (filter ?? null) as number | null }
}

/** `PUT /v1/bridge/appearance`: exactly the contract's fields. */
export function parseAppearance(input: Record<string, unknown>): Appearance {
  only(input, ['colorScheme', 'accent', 'contrast', 'reducedMotion', 'textScale'])
  const { colorScheme, accent, contrast, reducedMotion, textScale } = input
  if (colorScheme !== 'light' && colorScheme !== 'dark') throw new BridgeInputError('colorScheme must be "light" or "dark"')
  if (typeof accent !== 'string' || !/^#[0-9A-Fa-f]{6}$/.test(accent)) throw new BridgeInputError('accent must be "#RRGGBB"')
  if (contrast !== 'normal' && contrast !== 'high') throw new BridgeInputError('contrast must be "normal" or "high"')
  if (typeof reducedMotion !== 'boolean') throw new BridgeInputError('reducedMotion must be a boolean')
  if (typeof textScale !== 'number' || !Number.isFinite(textScale) || textScale < 0.75 || textScale > 2) throw new BridgeInputError('textScale must be a number from 0.75 to 2')
  return { colorScheme, accent, contrast, reducedMotion, textScale }
}

function within(value: unknown, min: number, max: number): value is number {
  return typeof value === 'number' && Number.isFinite(value) && value >= min && value <= max
}

/** `PUT /v1/bridge/location`. */
export function parseLocation(input: Record<string, unknown>): SharedLocation {
  only(input, ['latitude', 'longitude', 'accuracy', 'altitude'])
  const { latitude, longitude, accuracy, altitude } = input
  if (!within(latitude, -90, 90)) throw new BridgeInputError('latitude must be a number from -90 to 90')
  if (!within(longitude, -180, 180)) throw new BridgeInputError('longitude must be a number from -180 to 180')
  if (!within(accuracy, 0, 100_000)) throw new BridgeInputError('accuracy must be a number of metres from 0 to 100000')
  if (altitude !== undefined && !within(altitude, -1000, 100_000)) throw new BridgeInputError('altitude must be a number of metres from -1000 to 100000')
  return { latitude, longitude, accuracy, altitude: altitude ?? null }
}

/**
 * Relays file chooser and scan requests to the phone sockets while a phone is connected, and their
 * answers back. Delivery is at most once; the ids delivered are remembered for 24 hours so
 * an answer can be checked against its request. `emit` sends to the phone sockets, except
 * those of the phone `exceptPhone` when given, and only to those that scan when
 * `scanners` is set. A scan request with no such socket (`canScan`) goes back to the guest
 * as `computer` at once, so `caboose-scan` fails rather than waiting on a phone app that
 * cannot answer it.
 */
export class BridgeRelay {
  private timer: ReturnType<typeof setInterval> | undefined
  private polling = false
  private readonly outstanding = new Map<string, Outstanding>()
  /** Bumped when the computer stops: work begun before then must not touch what follows. */
  private generation = 0
  /** The phone's latest appearance, applied at every wake. */
  appearance: Appearance | null = null
  /** Whether a connected phone socket answers scan requests (opened with `?scan=1`). */
  canScan: () => boolean = () => false

  constructor(
    private readonly guest: () => AgentGuest | undefined,
    private readonly emit: (event: BridgeEvent, exceptPhone?: string, scanners?: boolean) => void,
    private readonly pollMs = 1000,
    private readonly now: () => number = Date.now,
  ) {}

  /** Draining runs while `active`: the computer is running and a phone socket is connected. */
  setActive(active: boolean): void {
    if (active && !this.timer) {
      this.timer = setInterval(() => { void this.poll() }, this.pollMs)
      this.timer.unref()
      void this.poll()
    } else if (!active && this.timer) {
      clearInterval(this.timer)
      this.timer = undefined
    }
  }

  get active(): boolean { return this.timer !== undefined }

  /** Whether `id` was delivered and is not yet answered, withdrawn or expired. */
  pending(id: string): boolean {
    this.prune()
    return this.outstanding.has(id)
  }

  /** The computer left the running state: the requests it had open are gone with it. */
  computerStopped(): void {
    this.setActive(false)
    this.generation++
    this.outstanding.clear()
  }

  async poll(): Promise<void> {
    const guest = this.guest()
    if (!guest || this.polling) return
    this.polling = true
    const generation = this.generation
    try {
      const output = await bridgeCommand(guest, ['drain'], 10_000).catch(() => '')
      // A drain that outlived its computer run delivers nothing: those requests went with it.
      if (generation !== this.generation) return
      let parsed: unknown
      try { parsed = JSON.parse(output) } catch { return }
      const drained = record(parsed)
      if (!drained) return
      const { requests, cancels } = drained
      if (!Array.isArray(requests) || requests.length > MAX_DRAIN || !Array.isArray(cancels) || cancels.length > MAX_DRAIN) return
      this.prune()
      for (const raw of requests) {
        const request = parseBridgeRequest(raw)
        if (request && (request.type !== 'scan' || this.canScan())) {
          if (this.outstanding.has(request.id)) continue
          this.outstanding.set(request.id, { type: request.type, multiple: request.multiple, directory: request.directory, filters: request.filters.length, deliveredAt: this.now() })
          this.emit({ type: 'bridge.request', request }, undefined, request.type === 'scan')
          continue
        }
        // A claimed request no phone can be shown (malformed, or a scan without a phone app
        // that scans) goes back now: to the computer's own dialog, or caboose-scan fails.
        const id = request?.id ?? record(raw)?.id
        if (typeof id === 'string' && BRIDGE_ID.test(id)) {
          await bridgeCommand(guest, ['respond', JSON.stringify({ id, response: 'computer' })])
            .catch(error => console.error('Could not hand a bridge request back to the computer:', message(error)))
          if (generation !== this.generation) return
        }
      }
      for (const id of cancels) {
        if (typeof id === 'string' && BRIDGE_ID.test(id) && this.outstanding.delete(id)) this.emit({ type: 'bridge.cancel', id })
      }
    } finally { this.polling = false }
  }

  /**
   * `POST /v1/bridge/requests/:id`; `rawId` is the URL path segment, not decoded. The caller
   * holds the computer running. Other phones are told the request is gone.
   */
  async answer(rawId: string, input: Record<string, unknown>, phoneId?: string): Promise<void> {
    this.prune()
    const request = BRIDGE_ID.test(rawId) ? this.outstanding.get(rawId) : undefined
    if (!request) throw new AgentNotFoundError('bridge request not found')
    const answer = parseBridgeAnswer(rawId, input, request)
    const guest = this.guest()
    if (!guest) throw new AgentUnavailableError()
    // Taken now so a second answer to the same request is refused while this one is in flight.
    this.outstanding.delete(rawId)
    const generation = this.generation
    let output: string
    try {
      output = await bridgeCommand(guest, ['respond', JSON.stringify(answer)])
    } catch (error) {
      // Open again for a retry, unless the computer stopped meanwhile and took it with it.
      if (generation === this.generation) this.outstanding.set(rawId, request)
      throw new AgentOperationError(`The computer did not take the answer: ${message(error)}`)
    }
    let result: Record<string, unknown> | null = null
    try { result = record(JSON.parse(output)) } catch { /* Exit status 0 is the answer taken. */ }
    if (result?.answered === false) {
      // The application withdrew it, or it went to the computer's dialog, before the answer.
      this.emit({ type: 'bridge.cancel', id: rawId })
      throw new AgentNotFoundError('bridge request is no longer open')
    }
    this.emit({ type: 'bridge.cancel', id: rawId }, phoneId)
  }

  /** Applies the stored appearance to the running computer; nothing to do without one. */
  async applyAppearance(): Promise<void> {
    const appearance = this.appearance
    if (!appearance) return
    const guest = this.guest()
    if (!guest) throw new AgentUnavailableError()
    await bridgeCommand(guest, ['appearance', JSON.stringify(appearance)]).catch(error => {
      throw new AgentOperationError(`The computer did not take the appearance: ${message(error)}`)
    })
  }

  private prune(): void {
    const cutoff = this.now() - OUTSTANDING_MS
    for (const [id, request] of this.outstanding) if (request.deliveredAt <= cutoff) this.outstanding.delete(id)
  }
}

/** Atomically replaces /etc/geolocation as root, mode 0644; $1 is the file's content. */
export const GEOLOCATION_WRITE_SCRIPT = [
  'set -e',
  `t=$(mktemp /etc/.geolocation.XXXXXX)`,
  `trap 'rm -f "$t"' EXIT`,
  `printf '%s' "$1" > "$t"`,
  'chmod 0644 "$t"',
  `mv -f "$t" ${GEOLOCATION_FILE}`,
].join('\n')

/** GeoClue's static source format: latitude, longitude, altitude, accuracy, one per line. */
export function geolocationFile(location: SharedLocation): string {
  const altitude = location.altitude === null ? ALTITUDE_UNKNOWN : String(location.altitude)
  return `${location.latitude}\n${location.longitude}\n${altitude}\n${location.accuracy}\n`
}

/**
 * The phone's location in /etc/geolocation, where GeoClue's static source serves it. One
 * update is accepted every 5 seconds; 30 minutes without one, or a DELETE, removes the file.
 * A file left from before a park is removed when the computer next runs. Guest writes are
 * serialized so a removal never overtakes a later update.
 */
export class LocationShare {
  private expiry: ReturnType<typeof setTimeout> | undefined
  private lastAccepted = Number.NEGATIVE_INFINITY
  private queue: Promise<void> = Promise.resolve()

  constructor(
    private readonly guest: () => AgentGuest | undefined,
    private readonly now: () => number = Date.now,
  ) {}

  get sharing(): boolean { return this.expiry !== undefined }

  /** Writes a location; the caller holds the computer running. */
  async set(location: SharedLocation): Promise<void> {
    const guest = this.guest()
    if (!guest) throw new AgentUnavailableError()
    const now = this.now()
    if (now - this.lastAccepted < LOCATION_INTERVAL_MS) throw new BridgeRateLimitError('send a location at most once every 5 seconds')
    this.lastAccepted = now
    this.arm()
    await this.serial(() => guest.run('/bin/sh', ['-c', GEOLOCATION_WRITE_SCRIPT, 'sh', geolocationFile(location)], 15_000)).catch(error => {
      throw new AgentOperationError(`The computer did not take the location: ${message(error)}`)
    })
  }

  /** Stops sharing: removes the file from a running computer. */
  async clear(): Promise<void> {
    this.disarm()
    await this.remove().catch(error => {
      throw new AgentOperationError(`The computer did not remove the location: ${message(error)}`)
    })
  }

  /** The computer left the running state: its next run starts without a location. */
  computerStopped(): void { this.disarm() }
  /** Wait for a location expiry or update already sent to the guest. */
  async quiesce(): Promise<void> { await this.queue }

  /** The computer is running again: remove a location left on its disk from before. */
  computerRunning(): Promise<void> {
    return this.remove().catch(error => console.error('Could not remove a stale shared location:', message(error)))
  }

  private remove(): Promise<void> {
    const guest = this.guest()
    if (!guest) return Promise.resolve()
    return this.serial(() => guest.run('/bin/rm', ['-f', '--', GEOLOCATION_FILE], 15_000))
  }

  private arm(): void {
    this.disarm()
    this.expiry = setTimeout(() => {
      this.expiry = undefined
      void this.remove().catch(error => console.error('Could not remove an expired shared location:', message(error)))
    }, LOCATION_EXPIRY_MS)
    this.expiry.unref()
  }

  private disarm(): void {
    if (this.expiry) clearTimeout(this.expiry)
    this.expiry = undefined
  }

  private serial(work: () => Promise<unknown>): Promise<void> {
    const next = this.queue.then(work, work).then(() => {})
    this.queue = next.catch(() => {})
    return next
  }
}

function message(error: unknown): string {
  const text = error instanceof Error ? error.message : String(error)
  return text.replace(/^(Guest command failed|docker exec failed):\s*/, '').trim().slice(0, 300)
}

export class BridgeInputError extends Error {}
export class BridgeRateLimitError extends Error {}
