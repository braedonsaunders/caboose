import { AgentInputError, AgentUnavailableError, type AgentGuest } from './agents.js'
import { ownerEnv } from './display.js'

/**
 * Agent attachments and links onto the owner's display. Agent attachments use the
 * argument-only guest channel; shared files use the separate streaming service.
 */
export const HOME = '/home/caboose'
export const DOWNLOADS = `${HOME}/Downloads`
/** One argument stays well under Linux's 128 KiB per-argument limit; a multiple of 4 keeps chunks whole base64. */
const CHUNK_CHARS = 96 * 1024
/** Arguments per guest command, well under the 2 MiB total argument limit. */
const CHUNKS_PER_CALL = 8
const RUNUSER = '/usr/sbin/runuser'
const BASE64 = /^[A-Za-z0-9+/]*={0,2}$/

/** Decodes strict base64 (whitespace ignored), or throws an input error naming the field. */
export function decodeBase64(value: unknown, field: string): Buffer {
  if (typeof value !== 'string') throw new AgentInputError(`${field} must be base64`)
  const compact = value.replace(/\s+/g, '')
  if (compact.length % 4 !== 0 || !BASE64.test(compact)) throw new AgentInputError(`${field} must be base64`)
  return Buffer.from(compact, 'base64')
}

/**
 * A file name safe to create in a directory: the last path component, without control
 * characters or leading dots, at most 120 characters with its extension kept.
 */
export function sanitizeFileName(name: unknown): string {
  const raw = typeof name === 'string' ? name : ''
  const base = raw.split(/[\\/]/).pop() ?? ''
  let clean = base.normalize('NFC').replace(/[\u0000-\u001f\u007f]/g, '').trim().replace(/^\.+/, '').trim()
  if (clean.length > 120) {
    const { ext } = splitName(clean)
    const keep = ext.length <= 20 ? ext : ''
    clean = clean.slice(0, 120 - keep.length).trimEnd() + keep
  }
  return clean || 'file'
}

/** "report.final.pdf" → { stem: "report.final", ext: ".pdf" }; dotfiles and bare names have no extension. */
export function splitName(name: string): { stem: string; ext: string } {
  const dot = name.lastIndexOf('.')
  return dot > 0 && dot < name.length - 1 ? { stem: name.slice(0, dot), ext: name.slice(dot) } : { stem: name, ext: '' }
}

/** The first of "name.ext", "name (2).ext", … that is not in `taken`. */
export function uniqueName(name: string, taken: ReadonlySet<string>): string {
  if (!taken.has(name)) return name
  const { stem, ext } = splitName(name)
  for (let n = 2; ; n++) {
    const candidate = `${stem} (${n})${ext}`
    if (!taken.has(candidate)) return candidate
  }
}

/** Writes `data` to the guest path `part` as user caboose, creating its directory; the caller renames it into place. */
export async function writeGuestFile(guest: AgentGuest, part: string, data: Buffer): Promise<void> {
  await guest.run(RUNUSER, ['-u', 'caboose', '--', '/bin/sh', '-c', 'mkdir -p "${1%/*}" && : > "$1"', 'sh', part], 15_000)
  const encoded = data.toString('base64')
  for (let start = 0; start < encoded.length; start += CHUNK_CHARS * CHUNKS_PER_CALL) {
    const chunks: string[] = []
    for (let at = start; at < Math.min(encoded.length, start + CHUNK_CHARS * CHUNKS_PER_CALL); at += CHUNK_CHARS) {
      chunks.push(encoded.slice(at, at + CHUNK_CHARS))
    }
    await guest.run(RUNUSER, ['-u', 'caboose', '--', '/bin/sh', '-c',
      'f=$1; shift; for c in "$@"; do printf %s "$c"; done | base64 -d >> "$f"', 'sh', part, ...chunks], 30_000)
  }
}

/** Opens a file or URL on the owner's display (run with its launch environment) with the desktop's default handler, detached. */
const OPEN_SCRIPT = [
  'export HOME=/home/caboose',
  '[ -d /run/user/1000 ] && export XDG_RUNTIME_DIR=/run/user/1000 DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus',
  'if command -v xdg-open >/dev/null 2>&1; then opener="xdg-open"',
  'elif command -v gio >/dev/null 2>&1; then opener="gio open"',
  'else echo "The computer has no xdg-open or gio to open this with." >&2; exit 1; fi',
  'setsid $opener "$1" > /dev/null 2>&1 < /dev/null &',
].join('\n')

export async function openOnDisplay(guest: AgentGuest, target: string): Promise<void> {
  await guest.run(RUNUSER, ['-u', 'caboose', '--', '/usr/bin/env', ...ownerEnv(guest), '/bin/sh', '-c', OPEN_SCRIPT, 'sh', target], 15_000)
}

/** `POST /v1/open`: `{ url }` → opens an http(s) URL in the default browser on the owner's display. */
export async function openUrl(guest: AgentGuest | undefined, input: Record<string, unknown>): Promise<{ opened: true }> {
  const url = parseWebUrl(input.url)
  if (!guest) throw new AgentUnavailableError()
  await openOnDisplay(guest, url)
  return { opened: true }
}

export function parseWebUrl(value: unknown): string {
  if (typeof value !== 'string' || !value || value.length > 8192 || /[\u0000- \u007f]/.test(value)) {
    throw new AgentInputError('url must be an http or https URL')
  }
  let url: URL
  try { url = new URL(value) } catch { throw new AgentInputError('url must be an http or https URL') }
  if (url.protocol !== 'http:' && url.protocol !== 'https:') throw new AgentInputError('url must be an http or https URL')
  return url.href
}
