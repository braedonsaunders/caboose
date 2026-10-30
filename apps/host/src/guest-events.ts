import { randomBytes } from 'node:crypto'

export const EVENT_CHANNELS = ['bridge.request', 'bridge.cancel', 'phone', 'notification', 'now-playing', 'media', 'agent.tick', 'agent.mailbox', 'fs'] as const
export type EventChannel = typeof EVENT_CHANNELS[number]
export type SubscribeEvents = (channel: EventChannel, accept: (record: unknown) => void | Promise<void>) => () => void
export interface EventTask { id: string; offset: number; turn?: number }
const MAX_RESPONSE = 2 * 1024 * 1024
const MAX_RECORD = 1024 * 1024

/** Read incrementally: Content-Length is not a trustworthy allocation bound. */
export async function readEventResponse(response: Response): Promise<{ cursor: string; records: Array<{ channel: EventChannel; receipt?: string; record: unknown }> }> {
  if (!response.ok || !response.body) { await response.body?.cancel(); throw new Error('Guest events unavailable') }
  const reader = response.body.getReader()
  const chunks: Uint8Array[] = []
  let length = 0
  try {
    for (;;) {
      const part = await reader.read()
      if (part.done) break
      length += part.value.byteLength
      if (length > MAX_RESPONSE) throw new Error('Guest events response exceeds limit')
      chunks.push(part.value)
    }
  } finally { await reader.cancel().catch(() => {}); reader.releaseLock() }
  const value = JSON.parse(Buffer.concat(chunks).toString('utf8'))
  if (!value || typeof value.cursor !== 'string' || value.cursor.length > 128 || !Array.isArray(value.records) || value.records.length > 128) throw new Error('Invalid guest events response')
  for (const record of value.records) {
    if (!record || !EVENT_CHANNELS.includes(record.channel) || !Object.hasOwn(record, 'record')
      || (record.receipt !== undefined && (typeof record.receipt !== 'string' || record.receipt.length > 1024))
      || Buffer.byteLength(JSON.stringify(record)) > (record.channel.startsWith('agent.') ? MAX_RECORD : 256 * 1024)) throw new Error('Invalid guest event')
  }
  return value
}

/** One serialized, bounded receiver per computer; a failed consumer never acknowledges. */
export class GuestEvents {
  private readers = new Map<EventChannel, (record: unknown) => void | Promise<void>>()
  private running = false
  private generation = 0
  private session = randomBytes(16).toString('hex')
  private cursor = ''
  private acks: string[] = []
  private abort?: AbortController
  private retry?: ReturnType<typeof setTimeout>
  private pumping = false
  private phone = false
  private presenceTimer?: ReturnType<typeof setInterval>
  private presenceAbort?: AbortController
  private presenceBusy = false
  constructor(private endpoint: () => { url: string; token: string } | undefined,
    private tasks: () => EventTask[] = () => [], private transport: typeof fetch = fetch) {}

  readonly subscribe: SubscribeEvents = (channel, accept) => {
    if (this.readers.has(channel)) throw new Error(`Duplicate guest event channel: ${channel}`)
    this.readers.set(channel, accept)
    this.refresh()
    return () => { if (this.readers.get(channel) === accept) { this.readers.delete(channel); this.refresh() } }
  }

  setPhone(active: boolean): void {
    if (this.phone === active) return
    this.phone = active
    this.refresh()
    this.syncPresence()
  }
  private syncPresence(): void {
    if (this.presenceTimer) clearInterval(this.presenceTimer)
    this.presenceTimer = undefined
    this.presenceAbort?.abort()
    if (!this.running) return
    void this.renewPresence()
    if (this.phone) {
      this.presenceTimer = setInterval(() => { void this.renewPresence() }, 1000)
      this.presenceTimer.unref()
    }
  }
  private async renewPresence(): Promise<void> {
    if (this.presenceBusy || !this.running) return
    const endpoint = this.endpoint()
    if (!endpoint) return
    this.presenceBusy = true
    const abort = new AbortController()
    this.presenceAbort = abort
    try {
      const response = await this.transport(new URL('/events/presence', endpoint.url), {
        method: 'POST', headers: { Authorization: `Bearer ${endpoint.token}`, 'Content-Type': 'application/json' },
        body: JSON.stringify({ session: this.session, generation: this.generation, phone: this.phone }),
        signal: AbortSignal.any([abort.signal, AbortSignal.timeout(2000)]),
      })
      await response.body?.cancel()
    } catch { /* Missing renewals expire naturally under the guest's three-second contract. */ }
    finally { this.presenceBusy = false }
  }
  setRunning(active: boolean): void {
    if (this.running === active) return
    this.stop()
    this.running = active
    if (active) { void this.pump(); if (this.phone) this.syncPresence() }
  }
  /** Task creation/retirement and subscription changes interrupt the outstanding wait. */
  refresh(): void {
    this.generation++
    this.cursor = ''
    this.abort?.abort()
    if (this.retry) clearTimeout(this.retry)
    this.retry = undefined
    if (this.running && !this.pumping) void this.pump()
  }
  stop(): void {
    this.running = false
    if (this.presenceTimer) clearInterval(this.presenceTimer)
    this.presenceTimer = undefined
    this.presenceAbort?.abort()
    this.generation++
    this.abort?.abort()
    if (this.retry) clearTimeout(this.retry)
    this.retry = undefined
    this.cursor = ''
    this.acks = []
  }

  private async pump(): Promise<void> {
    if (this.pumping || !this.running) return
    this.pumping = true
    let failed = false
    try {
      while (this.running) {
        const generation = this.generation
        const abort = new AbortController()
        this.abort = abort
        try {
          const endpoint = this.endpoint()
          if (!endpoint) throw new Error('Guest Files endpoint unavailable')
          const tasks = this.tasks()
          if (tasks.length > 256 || tasks.some(task => !/^[0-9a-f-]{36}$/.test(task.id) || !Number.isSafeInteger(task.offset) || task.offset < 0)) throw new Error('Invalid guest event tasks')
          const acks = this.acks.slice()
          const response = await this.transport(new URL('/events', endpoint.url), {
            method: 'POST', headers: { Authorization: `Bearer ${endpoint.token}`, 'Content-Type': 'application/json' },
            body: JSON.stringify({ session: this.session, generation, cursor: this.cursor, channels: [...this.readers.keys()], tasks, phone: this.phone, acks }),
            signal: AbortSignal.any([abort.signal, AbortSignal.timeout(25000)]),
          })
          const batch = await readEventResponse(response)
          if (!this.running || generation !== this.generation) continue
          this.acks.splice(0, acks.length)
          for (const event of batch.records) {
            if (!this.running || generation !== this.generation) break
            const accept = this.readers.get(event.channel)
            // Unsubscribed channels cannot consume guest records.
            if (!accept) throw new Error('Unsubscribed guest event')
            await accept(event.record)
            if (!this.running || generation !== this.generation) break
            if (event.receipt) this.acks.push(event.receipt)
          }
          if (generation === this.generation) this.cursor = batch.cursor
        } catch {
          if (!this.running) break
          if (generation !== this.generation) continue
          this.cursor = '' // Authoritative records replay after consumer/transport failure.
          failed = true
          break
        }
      }
    } finally {
      this.pumping = false
      if (this.running) {
        if (failed) {
          this.retry = setTimeout(() => { this.retry = undefined; void this.pump() }, 1000)
          this.retry.unref()
        } else void this.pump()
      }
    }
  }
}
