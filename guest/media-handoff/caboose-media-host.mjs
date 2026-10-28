#!/usr/bin/env node
// Native messaging host com.caboose.media (no dependencies). Chromium starts it for the
// Caboose media handoff extension and talks to it over stdin/stdout, each message a
// 32-bit little-endian length then UTF-8 JSON.
//
//   extension → host  { type: "media", media: <state> | null }
//   host → extension  { type: "command", id, action: "pause" | "play", position? }
//
// It keeps $HOME/.cache/caboose/media.json equal to the latest state (atomically replaced;
// removed when nothing plays), and forwards each new command that caboose-host writes to
// $HOME/.cache/caboose/media-command.json. media-host.pid lets caboose-host tell a live
// state file from one left behind by a browser that is no longer running.
import { mkdirSync, readFileSync, renameSync, rmSync, watch, writeFileSync } from 'node:fs'
import { homedir } from 'node:os'
import { join } from 'node:path'

const DIR = join(homedir(), '.cache', 'caboose')
const STATE = join(DIR, 'media.json')
const COMMAND = join(DIR, 'media-command.json')
const PID = join(DIR, 'media-host.pid')
const ID = /^[A-Za-z0-9._-]{1,64}$/
// Chromium refuses messages over 1 MiB from a host; it never sends us anything near 1 MiB.
const MAX_MESSAGE = 1024 * 1024
const log = message => process.stderr.write(`caboose-media-host: ${message}\n`)

function http(value, max) {
  if (typeof value !== 'string' || value.length > max) return false
  try { return ['http:', 'https:'].includes(new URL(value).protocol) } catch { return false }
}
function seconds(value) { return typeof value === 'number' && Number.isFinite(value) && value >= 0 && value <= 1e9 }

/** The state file's contents, or undefined if the extension sent something malformed. */
function validState(media) {
  if (!media || typeof media !== 'object') return undefined
  const { id, page, title, src, kind, position, duration, paused, updatedAt } = media
  if (typeof id !== 'string' || !ID.test(id) || !http(page, 4096) || typeof title !== 'string') return undefined
  if (!['page', 'hls', 'video'].includes(kind) || typeof paused !== 'boolean') return undefined
  // A page hands over the page; hls and video hand over their source.
  if (kind === 'page' ? src !== undefined : !http(src, 4096)) return undefined
  if (!seconds(position) || !(duration === null || seconds(duration)) || !Number.isSafeInteger(updatedAt) || updatedAt < 0) return undefined
  return {
    id, page, title: title.slice(0, 300), ...(src ? { src } : {}), kind,
    position, duration, paused, updatedAt,
  }
}

/** A command caboose-host wrote, or undefined. */
function validCommand(command) {
  if (!command || typeof command !== 'object') return undefined
  const { seq, id, action, position } = command
  if (!Number.isSafeInteger(seq) || seq < 1 || typeof id !== 'string' || !ID.test(id)) return undefined
  if (action !== 'pause' && action !== 'play') return undefined
  if (position !== undefined && !seconds(position)) return undefined
  return { seq, id, action, ...(position !== undefined ? { position } : {}) }
}

function writeAtomic(path, text) {
  const temporary = `${path}.${process.pid}.tmp`
  writeFileSync(temporary, text, { mode: 0o600 })
  renameSync(temporary, path)
}

function writeState(media) {
  if (media === null) { rmSync(STATE, { force: true }); return }
  const state = validState(media)
  if (!state) { log('ignored a malformed media state'); return }
  writeAtomic(STATE, JSON.stringify(state) + '\n')
}

function send(message) {
  const body = Buffer.from(JSON.stringify(message), 'utf8')
  const header = Buffer.alloc(4)
  header.writeUInt32LE(body.length, 0)
  process.stdout.write(Buffer.concat([header, body]))
}

function readCommand() {
  try { return validCommand(JSON.parse(readFileSync(COMMAND, 'utf8'))) } catch { return undefined }
}

mkdirSync(DIR, { recursive: true, mode: 0o700 })
// A new host means a new browser session or a restarted service worker, which republishes.
rmSync(STATE, { force: true })
writeAtomic(PID, `${process.pid}\n`)
// A command left from before this host started is history, not an instruction.
let lastSeq = readCommand()?.seq ?? 0

function checkCommand() {
  const command = readCommand()
  if (!command || command.seq <= lastSeq) return
  lastSeq = command.seq
  const { seq, ...forward } = command
  send({ type: 'command', ...forward })
}
try {
  watch(DIR, (_event, name) => { if (!name || name === 'media-command.json') checkCommand() }).on('error', () => {})
} catch (error) {
  log(`watching ${DIR} failed, polling only: ${error.message}`)
}
// inotify misses nothing on a local disk, but a poll costs one tiny read a second.
setInterval(checkCommand, 1000).unref()

let buffer = Buffer.alloc(0)
process.stdin.on('data', chunk => {
  buffer = Buffer.concat([buffer, chunk])
  while (buffer.length >= 4) {
    const length = buffer.readUInt32LE(0)
    if (length > MAX_MESSAGE) { log('message too large'); shutdown(1) }
    if (buffer.length < 4 + length) break
    const body = buffer.subarray(4, 4 + length)
    buffer = buffer.subarray(4 + length)
    let message
    try { message = JSON.parse(body.toString('utf8')) } catch { log('ignored a message that is not JSON'); continue }
    if (message?.type === 'media') writeState(message.media)
  }
})

function shutdown(code) {
  // The browser closed (or dropped the port): nothing is playing any more, unless a newer
  // host (a restarted service worker) has already taken over the files.
  try {
    if (readFileSync(PID, 'utf8').trim() === String(process.pid)) {
      rmSync(STATE, { force: true })
      rmSync(PID, { force: true })
    }
  } catch {}
  process.exit(code)
}
process.stdin.on('end', () => shutdown(0))
process.on('SIGTERM', () => shutdown(0))
process.on('SIGINT', () => shutdown(0))
