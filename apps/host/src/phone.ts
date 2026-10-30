import type { EventSubscribe } from './event-adapters.js'
import type { AgentGuest } from './agents.js'
import { AgentInputError, AgentUnavailableError } from './agents.js'

export const PHONE_MAX_BYTES = 10 * 1024 * 1024
const ID = /^[0-9a-f]{32}$/
const SCHEMES = new Set(['http:', 'https:', 'mailto:', 'tel:', 'sms:', 'facetime:', 'facetime-audio:', 'maps:', 'geo:'])
export type PhoneEvent = { type: 'phone.open'; url: string } | {
  type: 'phone.share' | 'phone.print'; id: string; path: string; name: string; size: number; contentType: string
}

/** The guest is owner-controlled but may send malformed data. Never relay an arbitrary path. */
export function parsePhoneEvent(value: unknown): PhoneEvent | null {
  if (!value || typeof value !== 'object' || Array.isArray(value)) return null
  const e = value as Record<string, unknown>
  if (e.type === 'phone.open') {
    if (typeof e.url !== 'string' || !e.url || e.url.length > 8192 || /[\x00-\x20\x7f]/.test(e.url)) return null
    try { if (!SCHEMES.has(new URL(e.url).protocol)) return null } catch { return null }
    return { type: e.type, url: e.url }
  }
  if (e.type !== 'phone.share' && e.type !== 'phone.print') return null
  if (typeof e.id !== 'string' || !ID.test(e.id) || e.path !== `/home/caboose/.cache/caboose/phone/files/${e.id}`) return null
  if (typeof e.name !== 'string' || !e.name || e.name === '.' || e.name === '..' || e.name.length > 200 || /[\x00-\x1f\x7f/\\]/.test(e.name)) return null
  if (!Number.isSafeInteger(e.size) || (e.size as number) < 0 || (e.size as number) > PHONE_MAX_BYTES) return null
  if (typeof e.contentType !== 'string' || !/^[\w.+-]+\/[\w.+-]+$/.test(e.contentType) || e.contentType.length > 127) return null
  if (e.type === 'phone.print' && e.contentType !== 'application/pdf') return null
  return { type: e.type, id: e.id, path: e.path as string, name: e.name, size: e.size as number, contentType: e.contentType }
}

const RUN = '/usr/sbin/runuser'
async function phoneCommand(guest: AgentGuest, ...args: string[]): Promise<string> {
  return guest.run(RUN, ['-u', 'caboose', '--', '/usr/local/bin/caboose-phone', ...args], 15_000)
}

/** Temporary fallback for small files; the iOS downloader is replaceable by /v1/fs. */
export async function readPhoneFile(guest: AgentGuest | undefined, id: string): Promise<{ data: string }> {
  if (!ID.test(id)) throw new AgentInputError('Invalid phone file id')
  if (!guest) throw new AgentUnavailableError()
  const sizeText = (await phoneCommand(guest, 'info', id)).trim()
  if (!/^\d+$/.test(sizeText)) throw new Error('Invalid guest file size')
  const size = Number(sizeText)
  if (!Number.isSafeInteger(size) || size > PHONE_MAX_BYTES) throw new Error('Invalid guest file size')
  const parts: Buffer[] = []
  for (let offset = 0; offset < size; offset += 49152) {
    const length = Math.min(49152, size - offset)
    const encoded = await phoneCommand(guest, 'read', id, String(offset), String(length))
    if (!/^[A-Za-z0-9+/]*={0,2}$/.test(encoded) || encoded.length % 4 !== 0) throw new Error('Invalid guest file data')
    const part = Buffer.from(encoded, 'base64')
    if (part.length !== length) throw new Error('Guest file changed during download')
    parts.push(part)
  }
  return { data: Buffer.concat(parts).toString('base64') }
}

/** At-most-once delivery while an authenticated control client is connected. */
export class PhoneHandoff {
  private timer?: () => void
  private polling = false
  constructor(private guest: () => AgentGuest | undefined, private emit: (event: PhoneEvent) => void, private pollMs = 1000, private subscribe?: EventSubscribe) {}
  setActive(active: boolean): void {
    if (active && !this.timer) {
      this.timer = this.subscribe?.('phone', record => this.accept(record)) ?? (() => {})
    } else if (!active && this.timer) { this.timer(); this.timer = undefined }
  }
  accept(raw: unknown): void {
    const event = parsePhoneEvent(raw)
    if (event) this.emit(event)
  }
  async poll(): Promise<void> {
    const guest = this.guest()
    if (!guest || this.polling) return
    this.polling = true
    try {
      const output = await phoneCommand(guest, 'drain').catch(() => '')
      let list: unknown
      try { list = JSON.parse(output) } catch { return }
      if (!Array.isArray(list) || list.length > 50) return
      for (const raw of list) {
        const event = parsePhoneEvent(raw)
        if (event) this.emit(event)
      }
    } finally { this.polling = false }
  }
}
