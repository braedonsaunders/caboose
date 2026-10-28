#!/usr/bin/env node
// caboose-agentd — runs any Agent Client Protocol (ACP) agent inside the computer on behalf of
// caboose-host. The host only reads and writes files (it has no stdin channel into the guest),
// so this process is the ACP client: it starts the agent, speaks JSON-RPC to it over stdio,
// and turns the conversation into an agent-neutral transcript plus approval files the host
// polls. See docs/architecture.md § Agents and guest/agentd/README.md for the file protocol.
//
//   caboose-agentd run <task dir>         one task: prompts from <dir>/inbox, transcript.jsonl out
//   caboose-agentd install <spec base64>  prefetch an agent, learn its sign-in methods, record it
//   caboose-agentd probe <spec base64>    initialize only: learn and record its sign-in methods
//   caboose-agentd sign-in <spec base64>  run one sign-in method, on the phone or the owner's display
//   caboose-agentd sign-in-callback <id> <attempt> <url>  deliver a page a sign-in on the phone was sent back to
//   caboose-agentd sign-in-cancel <id> <attempt>  stop the agent's running sign-in if it is that attempt
//   caboose-agentd state                  print what is installed and known, as JSON
//   caboose-agentd set-env <id> <json>    change an agent's environment file: { set?, remove? }
import { spawn } from 'node:child_process'
import { createHash, randomUUID } from 'node:crypto'
import { createWriteStream, existsSync, readFileSync } from 'node:fs'
import {
  appendFile, chmod, mkdir, open, readdir, readFile, realpath, rename, rm, stat, unlink, writeFile,
} from 'node:fs/promises'
import { homedir } from 'node:os'
import { basename, dirname, isAbsolute, join, relative, resolve, sep } from 'node:path'
import { Readable, Writable } from 'node:stream'
import { pipeline } from 'node:stream/promises'
import { setTimeout as sleep } from 'node:timers/promises'
import { pathToFileURL } from 'node:url'
import * as acp from '@agentclientprotocol/sdk'

const VERSION = JSON.parse(readFileSync(new URL('./package.json', import.meta.url), 'utf8')).version
const HOME = process.env.HOME || homedir()
const AGENTS_DIR = join(HOME, '.local', 'share', 'caboose', 'agents')
const DESKTOP_MCP = process.env.CABOOSE_DESKTOP_MCP ?? '/opt/caboose/desktop-mcp.mjs'
const AGENT_TOOLS = new URL('./agent-tools.mjs', import.meta.url).pathname
const POLL_MS = Number(process.env.CABOOSE_AGENTD_POLL_MS) || 250
const CANCEL_GRACE_MS = Number(process.env.CABOOSE_AGENTD_CANCEL_GRACE_MS) || 15_000
const INITIALIZE_TIMEOUT_MS = Number(process.env.CABOOSE_AGENTD_INIT_TIMEOUT_MS) || 120_000
const SIGN_IN_TIMEOUT_MS = 30 * 60_000
const DEFAULT_IDLE_MS = 10 * 60_000
/** How long a freshly started runner waits for its first prompt before deciding it was started by mistake. */
const STARTUP_WAIT_MS = 30_000
const MAX_TEXT = 512 * 1024
/** How often the message being written is saved for the host to stream, at most. */
const DRAFT_MS = Number(process.env.CABOOSE_AGENTD_DRAFT_MS) || 200
/** The most of a message being written that the draft carries: its end. */
const MAX_DRAFT = 16_000
const MAX_SUMMARY = 2000
const MAX_READ_BYTES = 10 * 1024 * 1024
const MAX_IMAGE_BYTES = 10 * 1024 * 1024
const MAX_DOWNLOAD_BYTES = 2 * 1024 * 1024 * 1024
const RECAP_CHARS = 6000
const IMAGE_TYPES = new Map([['.png', 'image/png'], ['.jpg', 'image/jpeg'], ['.jpeg', 'image/jpeg'], ['.gif', 'image/gif'], ['.webp', 'image/webp']])
const AUTH_REQUIRED = -32000
const AGENT_ID = /^[a-z0-9][a-z0-9._-]{0,63}$/
const ENV_NAME = /^[A-Za-z_][A-Za-z0-9_]{0,127}$/

// ---------------------------------------------------------------------------------------------
// Agent specs: what caboose-host resolved from the ACP registry for linux-x86_64.

/**
 * Validates an agent spec from the host: { id, name, version, distribution: "npx" | "uvx" |
 * "binary", package? (npx, uvx), archive?, sha256?, cmd? (binary), args, env }.
 */
export function readSpec(value) {
  if (!value || typeof value !== 'object') throw new Error('agent spec must be an object')
  const { id, name, version, distribution } = value
  if (typeof id !== 'string' || !AGENT_ID.test(id)) throw new Error('agent id is invalid')
  if (typeof version !== 'string' || !/^[0-9A-Za-z][0-9A-Za-z.+_-]{0,63}$/.test(version)) throw new Error('agent version is invalid')
  if (!['npx', 'uvx', 'binary'].includes(distribution)) throw new Error('agent distribution must be npx, uvx or binary')
  const args = value.args ?? []
  if (!Array.isArray(args) || args.some(arg => typeof arg !== 'string')) throw new Error('agent args must be strings')
  const env = value.env ?? {}
  if (typeof env !== 'object' || Array.isArray(env) || Object.entries(env).some(([key, item]) => !ENV_NAME.test(key) || typeof item !== 'string')) {
    throw new Error('agent env must map variable names to strings')
  }
  const spec = { id, name: typeof name === 'string' && name ? name : id, version, distribution, args, env }
  if (distribution === 'binary') {
    if (typeof value.archive !== 'string') throw new Error('a binary agent needs an archive URL')
    const url = new URL(value.archive)
    if (url.protocol !== 'https:' && !(url.protocol === 'http:' && value.sha256)) throw new Error('a binary agent is downloaded over https, or verified by sha256')
    if (value.sha256 !== undefined && (typeof value.sha256 !== 'string' || !/^[0-9a-fA-F]{64}$/.test(value.sha256))) throw new Error('sha256 must be 64 hex characters')
    if (typeof value.cmd !== 'string' || !value.cmd) throw new Error('a binary agent needs cmd')
    return { ...spec, archive: url.href, sha256: value.sha256?.toLowerCase(), cmd: value.cmd }
  }
  if (typeof value.package !== 'string' || !value.package || /\s/.test(value.package) || value.package.startsWith('-')) {
    throw new Error('agent package is invalid')
  }
  return { ...spec, package: value.package }
}

/** Where a binary agent's version lives, and its executable inside it. */
export function binaryPaths(spec) {
  const dir = join(AGENTS_DIR, spec.id, spec.version)
  const executable = resolve(dir, spec.cmd.replaceAll('\\', '/'))
  if (!executable.startsWith(dir + sep)) throw new Error('cmd must stay inside the agent directory')
  return { dir, executable }
}

/**
 * The program and arguments that start an agent. `extraArgs` replaces the registry's own
 * arguments, which is how a terminal sign-in method runs the same program for its login flow.
 */
export function launchCommand(spec, extraArgs) {
  const tail = extraArgs ?? spec.args
  if (spec.distribution === 'npx') return { command: 'npx', args: ['-y', spec.package, ...tail] }
  if (spec.distribution === 'uvx') return { command: 'uvx', args: [spec.package, ...tail] }
  return { command: binaryPaths(spec).executable, args: [...tail] }
}

/** Downloads, verifies and unpacks a binary agent once per version. */
export async function ensureBinary(spec) {
  const { dir, executable } = binaryPaths(spec)
  if (existsSync(join(dir, '.caboose-complete')) && existsSync(executable)) return executable
  const parent = dirname(dir)
  await mkdir(parent, { recursive: true })
  const work = `${dir}.partial-${process.pid}`
  await rm(work, { recursive: true, force: true })
  await mkdir(work, { recursive: true })
  try {
    const response = await fetch(spec.archive, { redirect: 'follow' })
    if (!response.ok || !response.body) throw new Error(`Downloading ${spec.name} failed: HTTP ${response.status}`)
    const archiveName = decodeURIComponent(new URL(spec.archive).pathname.split('/').pop() || 'download')
    const archive = join(work, `.download-${archiveName.replace(/[^A-Za-z0-9._+-]/g, '_')}`)
    const hash = createHash('sha256')
    let size = 0
    await pipeline(Readable.fromWeb(response.body), async function* (source) {
      for await (const chunk of source) {
        size += chunk.length
        if (size > MAX_DOWNLOAD_BYTES) throw new Error(`${spec.name} is larger than 2 GiB`)
        hash.update(chunk)
        yield chunk
      }
    }, createWriteStream(archive))
    const digest = hash.digest('hex')
    if (spec.sha256 && digest !== spec.sha256) throw new Error(`${spec.name} failed verification: sha256 ${digest} is not ${spec.sha256}`)
    const lower = archiveName.toLowerCase()
    const target = resolve(work, spec.cmd.replaceAll('\\', '/'))
    if (lower.endsWith('.zip')) await exec('unzip', ['-q', '-o', archive, '-d', work])
    else if (lower.endsWith('.tar.gz') || lower.endsWith('.tgz')) await exec('tar', ['-xzf', archive, '-C', work, '--no-same-owner'])
    else if (lower.endsWith('.tar.bz2') || lower.endsWith('.tbz2')) await exec('tar', ['-xjf', archive, '-C', work, '--no-same-owner'])
    else if (lower.endsWith('.tar.xz') || lower.endsWith('.txz')) await exec('tar', ['-xJf', archive, '-C', work, '--no-same-owner'])
    else if (lower.endsWith('.tar')) await exec('tar', ['-xf', archive, '-C', work, '--no-same-owner'])
    else {
      // A raw executable: it is the command.
      await mkdir(dirname(target), { recursive: true })
      await rename(archive, target)
    }
    await rm(archive, { force: true })
    if (!existsSync(target)) throw new Error(`${spec.name}'s archive has no ${spec.cmd}`)
    await chmod(target, 0o755)
    await writeFile(join(work, '.caboose-complete'), JSON.stringify({ archive: spec.archive, sha256: digest, verified: Boolean(spec.sha256) }))
    await rm(dir, { recursive: true, force: true })
    await rename(work, dir)
  } catch (error) {
    await rm(work, { recursive: true, force: true })
    throw error
  }
  return executable
}

function exec(command, args, options = {}) {
  return new Promise((resolvePromise, reject) => {
    const child = spawn(command, args, { stdio: ['ignore', 'pipe', 'pipe'], ...options })
    let output = ''
    child.stdout.on('data', chunk => { output += chunk })
    child.stderr.on('data', chunk => { output += chunk })
    child.on('error', reject)
    child.on('close', code => code === 0 ? resolvePromise(output) : reject(new Error(`${command} exited with ${code}: ${output.trim().slice(-600)}`)))
  })
}

/**
 * Reads the owner's environment file for an agent, ~/.config/caboose/agents/<id>.env:
 * KEY=VALUE lines, # comments and blank lines, no shell expansion; one pair of matching
 * quotes around a value is removed. The file must belong to this user and be closed to group
 * and others, or it is ignored. Problems are logged without values.
 */
export async function readEnvFile(id, warn = message => console.error(`caboose-agentd: ${message}`)) {
  const path = join(HOME, '.config', 'caboose', 'agents', `${id}.env`)
  let info
  try { info = await stat(path) } catch { return {} }
  if (!info.isFile()) { warn(`ignoring ${path}: not a regular file`); return {} }
  if (typeof process.getuid === 'function' && info.uid !== process.getuid()) { warn(`ignoring ${path}: it must be owned by ${process.env.USER || 'this user'}`); return {} }
  if (info.mode & 0o077) { warn(`ignoring ${path}: it must not be readable or writable by group or others (chmod 600)`); return {} }
  const env = {}
  const lines = (await readFile(path, 'utf8')).split(/\r?\n/)
  for (const [index, raw] of lines.entries()) {
    const line = raw.trim()
    if (!line || line.startsWith('#')) continue
    const equals = line.indexOf('=')
    const key = equals > 0 ? line.slice(0, equals).trim() : ''
    if (!ENV_NAME.test(key)) { warn(`ignoring line ${index + 1} of ${path}: expected KEY=VALUE`); continue }
    let value = line.slice(equals + 1).trim()
    if (value.length >= 2 && (value[0] === '"' || value[0] === "'") && value.at(-1) === value[0]) value = value.slice(1, -1)
    env[key] = value
  }
  return env
}

const ENV_DIR = join(HOME, '.config', 'caboose', 'agents')

/** The variable names an agent's environment file sets; never their values. */
export async function envNames(id) {
  return Object.keys(await readEnvFile(id, () => {})).sort()
}

/**
 * Sets and removes variables in an agent's environment file, keeping its other lines and
 * comments. Values are written in double quotes (the reader removes one pair), so leading
 * and trailing spaces and quote characters survive. The file is written whole, mode 0600,
 * and renamed into place. Returns the names it now sets.
 */
export async function setEnv(id, changes) {
  if (!AGENT_ID.test(id ?? '')) throw new Error('invalid agent id')
  const set = changes?.set ?? {}
  const remove = changes?.remove ?? []
  if (typeof set !== 'object' || Array.isArray(set) || !Array.isArray(remove)) throw new Error('changes must be { set?: { NAME: value }, remove?: [NAME] }')
  for (const [name, value] of Object.entries(set)) {
    if (!ENV_NAME.test(name)) throw new Error(`invalid variable name: ${name.slice(0, 130)}`)
    if (typeof value !== 'string' || /[\r\n\0]/.test(value) || value.length > 8192) throw new Error(`${name} must be a single line of at most 8192 characters`)
  }
  for (const name of remove) if (typeof name !== 'string' || !ENV_NAME.test(name)) throw new Error('invalid variable name to remove')
  const path = join(ENV_DIR, `${id}.env`)
  const lines = await readFile(path, 'utf8').then(text => text.split(/\r?\n/), () => [])
  const pending = new Map(Object.entries(set))
  const dropped = new Set(remove)
  const kept = []
  for (const line of lines) {
    const equals = line.indexOf('=')
    const name = equals > 0 && !line.trim().startsWith('#') ? line.slice(0, equals).trim() : ''
    if (name && dropped.has(name)) continue
    if (name && pending.has(name)) { kept.push(`${name}="${pending.get(name)}"`); pending.delete(name); continue }
    kept.push(line)
  }
  while (kept.length && kept.at(-1) === '') kept.pop()
  for (const [name, value] of pending) kept.push(`${name}="${value}"`)
  await mkdir(ENV_DIR, { recursive: true, mode: 0o700 })
  const temporary = `${path}.${randomUUID()}.tmp`
  await writeFile(temporary, kept.length ? kept.join('\n') + '\n' : '', { mode: 0o600 })
  await chmod(temporary, 0o600)
  await rename(temporary, path)
  return envNames(id)
}

// ---------------------------------------------------------------------------------------------
// The ACP connection to one agent process.

/**
 * The environment for a GUI on the owner's display: `vars` from the host (its launch
 * environment, such as DISPLAY or WAYLAND_DISPLAY), with the owner's session bus when it exists.
 */
function displayEnv(vars) {
  const env = Object.fromEntries(Object.entries(vars && typeof vars === 'object' ? vars : {}).filter(([key, value]) => ENV_NAME.test(key) && typeof value === 'string'))
  if (existsSync('/run/user/1000/bus')) Object.assign(env, { XDG_RUNTIME_DIR: '/run/user/1000', DBUS_SESSION_BUS_ADDRESS: 'unix:path=/run/user/1000/bus' })
  return env
}

/** The agent seat's launch environment the runner was started with, as the desktop tools need it. */
const SEAT_ENV = ['WAYLAND_DISPLAY', 'CABOOSE_DISPLAY_CONTROL', 'XAUTHORITY', 'XDG_RUNTIME_DIR', 'DBUS_SESSION_BUS_ADDRESS', 'GDK_BACKEND',
  'QT_QPA_PLATFORM', 'MOZ_ENABLE_WAYLAND', 'SDL_VIDEODRIVER', 'ELECTRON_OZONE_PLATFORM_HINT', 'GALLIUM_DRIVER', 'LIBVA_DRIVER_NAME',
  'GST_VA_ALL_DRIVERS', 'CABOOSE_VIDEO_SOCKET']

function seatEnv() {
  return [
    { name: 'CABOOSE_AGENT_DISPLAY', value: process.env.DISPLAY || ':101' },
    ...SEAT_ENV.filter(name => process.env[name]).map(name => ({ name, value: process.env[name] })),
  ]
}

const CLIENT_CAPABILITIES = {
  // File reads and writes go through Caboose, limited to the home directory.
  fs: { readTextFile: true, writeTextFile: true },
  // Agents run their own commands; Caboose does not host terminals for them.
  terminal: false,
  // Terminal sign-in methods run in a terminal the owner sees: on the phone, or a window on the display.
  auth: { terminal: true },
}

/**
 * Starts an agent and initializes ACP. `handlers` receives session updates and permission
 * requests; `unset` names variables the agent must not inherit. Resolves { connection, init,
 * child, exited, stderrTail(), close() }.
 */
async function startAgent(spec, { cwd, env = {}, unset = [], handlers = {}, log }) {
  if (spec.distribution === 'binary') await ensureBinary(spec)
  const { command, args } = launchCommand(spec)
  const childEnv = { ...process.env, ...spec.env, ...await readEnvFile(spec.id), ...env }
  for (const name of unset) delete childEnv[name]
  const child = spawn(command, args, { cwd, env: childEnv, stdio: ['pipe', 'pipe', 'pipe'] })
  child.stdin.on('error', () => {})
  let tail = ''
  let logged = 0
  child.stderr.on('data', chunk => {
    tail = (tail + chunk).slice(-4000)
    if (log && logged < 4 * 1024 * 1024) { logged += chunk.length; log.write(chunk) }
  })
  const exited = new Promise(resolvePromise => {
    child.on('error', error => { tail += `\n${error.message}`; resolvePromise({ code: null, error }) })
    child.on('exit', (code, signal) => resolvePromise({ code, signal }))
  })
  const app = acp.client({ name: 'caboose' })
    .onNotification('session/update', ({ params }) => handlers.update?.(params))
    .onRequest('session/request_permission', ({ params }) => handlers.permission ? handlers.permission(params) : { outcome: { outcome: 'cancelled' } })
    .onRequest('fs/read_text_file', ({ params }) => readTextFile(params))
    .onRequest('fs/write_text_file', ({ params }) => writeTextFile(params))
  const stream = acp.ndJsonStream(Writable.toWeb(child.stdin), Readable.toWeb(child.stdout))
  const connection = app.connect(stream)
  const close = async () => {
    try { connection.close() } catch {}
    if (child.exitCode === null && child.signalCode === null) {
      child.kill('SIGTERM')
      const done = await Promise.race([exited.then(() => true), sleep(3000).then(() => false)])
      if (!done) child.kill('SIGKILL')
    }
  }
  const died = exited.then(({ code, signal }) => { throw new AgentExited(code, signal, tail) })
  died.catch(() => {})
  /** The agent's exit, if it exits within `ms`: a lost connection is usually a dead agent. */
  const exitError = ms => Promise.race([died.catch(error => error), sleep(ms).then(() => undefined)])
  try {
    const init = await Promise.race([
      connection.agent.request('initialize', {
        protocolVersion: acp.PROTOCOL_VERSION,
        clientCapabilities: CLIENT_CAPABILITIES,
        clientInfo: { name: 'caboose', title: 'Caboose', version: VERSION },
      }),
      died,
      sleep(INITIALIZE_TIMEOUT_MS).then(() => { throw new Error(`${spec.name} did not answer initialize within ${INITIALIZE_TIMEOUT_MS / 1000} s`) }),
    ])
    await recordAuth(spec, init)
    return { connection, init, child, died, exitError, stderrTail: () => tail, close }
  } catch (error) {
    await close()
    throw error
  }
}

class AgentExited extends Error {
  constructor(code, signal, stderr) {
    const detail = stderr.trim().split('\n').slice(-5).join('\n')
    super(`The agent exited${code !== null && code !== undefined ? ` with code ${code}` : signal ? ` (${signal})` : ''}${detail ? `: ${detail}` : '.'}`)
  }
}

function isAuthRequired(error) { return error?.code === AUTH_REQUIRED }

function errorMessage(error) {
  if (!error) return 'Unknown error'
  const data = typeof error.data === 'string' ? error.data : error.data?.message ?? error.data?.details
  const message = String(error.message ?? error)
  return typeof data === 'string' && data && !message.includes(data) ? `${message}: ${data}` : message
}

/** Sign-in methods as clients see them: id, name, description and kind. Unknown kinds are left out. */
export function publicAuthMethods(methods) {
  if (!Array.isArray(methods)) return []
  return methods.slice(0, 20).flatMap(method => {
    if (!method || typeof method.id !== 'string' || typeof method.name !== 'string') return []
    const type = method.type === undefined || method.type === null || method.type === 'agent' ? 'agent' : method.type === 'terminal' ? 'terminal' : undefined
    if (!type) return []
    return [{ id: method.id.slice(0, 200), name: method.name.slice(0, 200), ...(typeof method.description === 'string' && method.description ? { description: method.description.slice(0, 500) } : {}), type }]
  })
}

async function recordAuth(spec, init) {
  const dir = join(AGENTS_DIR, spec.id)
  await mkdir(dir, { recursive: true })
  await writeJson(join(dir, 'auth.json'), {
    version: spec.version,
    authMethods: Array.isArray(init?.authMethods) ? init.authMethods : [],
    agentInfo: init?.agentInfo ?? null,
    probedAt: new Date().toISOString(),
  })
}

// ---------------------------------------------------------------------------------------------
// Files: the fs capability, limited to the home directory.

async function insideHome(path) {
  if (typeof path !== 'string' || !isAbsolute(path)) throw acp.RequestError.invalidParams(undefined, 'path must be absolute')
  const home = await realpath(HOME)
  let existing = resolve(path)
  const rest = []
  for (;;) {
    try { existing = await realpath(existing); break } catch {
      const parent = dirname(existing)
      if (parent === existing) break
      rest.unshift(basename(existing))
      existing = parent
    }
  }
  const final = join(existing, ...rest)
  const inside = relative(home, final)
  if (inside.startsWith('..') || isAbsolute(inside)) throw acp.RequestError.invalidParams(undefined, `${path} is outside the home directory`)
  return final
}

async function readTextFile({ path, line, limit }) {
  const real = await insideHome(path)
  let info
  try { info = await stat(real) } catch { throw acp.RequestError.resourceNotFound(pathToFileURL(path).href) }
  if (info.size > MAX_READ_BYTES) throw acp.RequestError.invalidParams(undefined, `${path} is larger than 10 MB`)
  let content = await readFile(real, 'utf8')
  if (line || limit) {
    const lines = content.split('\n')
    const start = Math.max(0, (line ?? 1) - 1)
    content = lines.slice(start, limit ? start + limit : undefined).join('\n')
  }
  return { content }
}

async function writeTextFile({ path, content }) {
  if (typeof content !== 'string') throw acp.RequestError.invalidParams(undefined, 'content must be a string')
  const real = await insideHome(path)
  await mkdir(dirname(real), { recursive: true })
  await writeFile(real, content)
  return {}
}

async function writeJson(path, value) {
  const temporary = join(dirname(path), `.${basename(path)}.${process.pid}.tmp`)
  const handle = await open(temporary, 'w', 0o600)
  try { await handle.writeFile(JSON.stringify(value)); await handle.sync() } finally { await handle.close() }
  await rename(temporary, path)
  await syncDirectory(dirname(path))
}

async function syncDirectory(path) {
  const handle = await open(path, 'r')
  try { await handle.sync() } finally { await handle.close() }
}

async function readBoundedFile(path, max) {
  const handle = await open(path, 'r')
  try {
    const buffer = Buffer.alloc(max + 1)
    const { bytesRead } = await handle.read(buffer, 0, buffer.length, 0)
    if (bytesRead > max) throw new Error('Oversized stored agent message')
    return buffer.subarray(0, bytesRead).toString('utf8')
  } finally { await handle.close() }
}

async function readJson(path) {
  try { return JSON.parse(await readFile(path, 'utf8')) } catch { return undefined }
}

// ---------------------------------------------------------------------------------------------
// The transcript: one JSON object per line, the same shape for every agent.

class Transcript {
  constructor(path) { this.path = path; this.chain = Promise.resolve() }
  write(event) {
    if (['turn_end', 'turn_failed', 'auth_required'].includes(event.type)) this.lastResult = event
    const line = JSON.stringify({ ...event, at: new Date().toISOString() }) + '\n'
    return this.then(() => appendFile(this.path, line), 'transcript write')
  }
  /** Runs `step` after every write before it, so files written alongside stay in order. */
  then(step, what) {
    this.chain = this.chain.then(step).catch(error => { this.error ??= error; console.error(`${what} failed:`, error) })
    return this.chain
  }
  flushed() { return this.chain }
}

/**
 * The message the agent is writing now, as `draft.json` `{ turn, after, kind, text }`, so the host can show
 * it before it is whole. Saved at most every DRAFT_MS, and removed before the whole message is
 * written to the transcript (on the transcript's own chain), so a reader that reads the
 * transcript and then the draft never sees one message in both.
 */
export class Draft {
  constructor(transcript, path) { this.transcript = transcript; this.path = path; this.pending = null; this.timer = null; this.saved = false }

  set(kind, text) {
    this.pending = { kind, text: text.length > MAX_DRAFT ? `…${text.slice(-(MAX_DRAFT - 1))}` : text }
    this.timer ??= setTimeout(() => { this.timer = null; this.save() }, DRAFT_MS)
  }

  save() {
    const value = this.pending && { ...this.pending, turn: this.turn }
    this.pending = null
    if (!value) return
    this.saved = true
    this.transcript.then(async () => {
      const after = (await stat(this.transcript.path).catch(() => ({ size: 0 }))).size
      await writeJson(this.path, { ...value, after })
    }, 'draft write')
  }

  /** Forgets any draft, including one an earlier runner left behind. */
  reset(turn = 1) {
    this.turn = turn
    this.saved = true
    this.clear()
  }

  clear() {
    clearTimeout(this.timer)
    this.timer = null
    this.pending = null
    if (!this.saved) return
    this.saved = false
    this.transcript.then(() => rm(this.path, { force: true }), 'draft removal')
  }
}

function clip(text, max = MAX_TEXT) { return text.length > max ? `${text.slice(0, max - 1)}…` : text }

/**
 * Turns ACP session updates into transcript events: message and thought chunks coalesced per
 * message, tool calls and their status changes, plans, mode changes, and the turn's usage.
 */
export class Normaliser {
  constructor(transcript, draft = null) {
    this.transcript = transcript
    this.draft = draft
    this.tools = new Map()
    this.live = false
    this.buffers = { text: null, thought: null }
    this.lastText = ''
    this.usage = null
  }

  begin(turn = 1) {
    this.live = true
    this.lastText = ''
    this.usage = null
    this.draft?.reset(turn)
  }

  update(update) {
    if (!this.live || !update || typeof update !== 'object') return
    switch (update.sessionUpdate) {
      case 'agent_message_chunk': return this.chunk('text', update)
      case 'agent_thought_chunk': return this.chunk('thought', update)
      case 'tool_call': {
        this.flush()
        const call = { title: String(update.title ?? 'Tool'), kind: update.kind ?? 'other', status: update.status ?? 'pending' }
        this.tools.set(update.toolCallId, { ...call, rawInput: update.rawInput })
        return this.transcript.write({ type: 'tool', id: update.toolCallId, ...call, ...detail(update.rawInput) })
      }
      case 'tool_call_update': {
        this.flush()
        const known = this.tools.get(update.toolCallId) ?? { title: 'Tool', kind: 'other', status: 'pending' }
        const next = { title: update.title ?? known.title, kind: update.kind ?? known.kind, status: update.status ?? known.status }
        this.tools.set(update.toolCallId, { ...next, rawInput: update.rawInput ?? known.rawInput })
        if (next.status === known.status && next.title === known.title) return
        return this.transcript.write({ type: 'tool_update', id: update.toolCallId, ...next })
      }
      case 'plan': {
        this.flush()
        const entries = Array.isArray(update.entries) ? update.entries.slice(0, 50).map(entry => ({ content: clip(String(entry?.content ?? ''), 500), status: entry?.status ?? 'pending' })) : []
        return this.transcript.write({ type: 'plan', entries })
      }
      case 'usage_update':
        this.usage = { used: update.used, size: update.size, ...(update.cost ? { cost: update.cost } : {}) }
        return
      case 'current_mode_update':
        this.flush()
        return this.transcript.write({ type: 'mode', modeId: update.currentModeId })
      default:
        return
    }
  }

  chunk(kind, update) {
    const content = update.content
    if (content?.type !== 'text' || typeof content.text !== 'string') return
    const other = kind === 'text' ? 'thought' : 'text'
    if (this.buffers[other]) this.flushOne(other)
    const id = update.messageId ?? null
    const buffer = this.buffers[kind]
    if (buffer && buffer.id !== id) this.flushOne(kind)
    if (!this.buffers[kind]) this.buffers[kind] = { id, text: '' }
    this.buffers[kind].text += content.text
    if (this.buffers[kind].text.trim()) this.draft?.set(kind, this.buffers[kind].text)
  }

  flushOne(kind) {
    const buffer = this.buffers[kind]
    this.buffers[kind] = null
    if (buffer) this.draft?.clear()
    if (!buffer || !buffer.text.trim()) return
    if (kind === 'text') this.lastText = buffer.text.trim()
    this.transcript.write({ type: kind, text: clip(buffer.text) })
  }

  flush() { this.flushOne('thought'); this.flushOne('text') }

  /** Ends the turn's live output; returns the turn's last message. */
  end() {
    this.flush()
    if (this.usage) this.transcript.write({ type: 'usage', ...this.usage })
    this.live = false
    return this.lastText
  }

  tool(id) { return this.tools.get(id) }
}

/** The part of a tool's input worth showing in one line: a command, a path, a URL or a query. */
function detail(input) {
  if (!input || typeof input !== 'object') return {}
  for (const key of ['command', 'cmd', 'file_path', 'path', 'url', 'pattern', 'query']) {
    const value = input[key]
    if (typeof value === 'string' && value) return { detail: clip(value, 300) }
    if (Array.isArray(value) && value.every(part => typeof part === 'string')) return { detail: clip(value.join(' '), 300) }
  }
  return {}
}

/** A copy of a tool input small enough to show the owner: long strings are cut. */
function preview(value, depth = 0) {
  if (typeof value === 'string') return value.length > 2000 ? `${value.slice(0, 2000)}…` : value
  if (Array.isArray(value)) return depth > 4 ? '[…]' : value.slice(0, 50).map(item => preview(item, depth + 1))
  if (value && typeof value === 'object') {
    if (depth > 4) return '{…}'
    return Object.fromEntries(Object.entries(value).slice(0, 50).map(([key, item]) => [key, preview(item, depth + 1)]))
  }
  return value
}

/** One line for the owner: the tool's title, plus its command or path when the title lacks it. */
export function describeToolCall(call) {
  const title = String(call?.title ?? '').trim() || String(call?.kind ?? 'Tool')
  const extra = detail(call?.rawInput).detail
  const text = extra && !title.includes(extra) ? `${title}: ${extra}` : title
  return text.length > 300 ? `${text.slice(0, 299)}…` : text
}

/**
 * The option that carries out the owner's decision: the requested option, else the first
 * allow_once (allow_always) or reject_once (reject_always). Undefined when there is none.
 */
export function chooseOption(options, decision) {
  const list = Array.isArray(options) ? options : []
  if (typeof decision.optionId === 'string') {
    const exact = list.find(option => option.optionId === decision.optionId)
    if (exact) return exact
  }
  const kinds = decision.allow ? ['allow_once', 'allow_always'] : ['reject_once', 'reject_always']
  for (const kind of kinds) {
    const found = list.find(option => option.kind === kind)
    if (found) return found
  }
  return undefined
}

// ---------------------------------------------------------------------------------------------
// One task.

function stopSummary(stopReason) {
  switch (stopReason) {
    case 'end_turn': return 'Done.'
    case 'cancelled': return 'Cancelled.'
    case 'refusal': return 'The agent declined to continue.'
    case 'max_tokens': return 'The agent reached its output limit.'
    case 'max_turn_requests': return 'The agent reached its limit of model requests for one turn.'
    default: return `The agent stopped (${stopReason}).`
  }
}

/** A recap of earlier turns for an agent that cannot reload its conversation. */
export function recapFrom(lines, beforeTurn) {
  const turns = new Map()
  for (const line of lines) {
    let event
    try { event = JSON.parse(line) } catch { continue }
    if (typeof event?.turn !== 'number' || event.turn >= beforeTurn) continue
    const entry = turns.get(event.turn) ?? {}
    if (event.type === 'user' && typeof event.text === 'string') entry.user = event.text
    if (event.type === 'turn_end' && typeof event.summary === 'string') entry.agent = event.summary
    if (event.type === 'turn_failed' && typeof event.message === 'string') entry.agent = `(failed: ${event.message})`
    turns.set(event.turn, entry)
  }
  const parts = []
  let used = 0
  for (const turn of [...turns.keys()].sort((a, b) => b - a)) {
    const { user, agent } = turns.get(turn)
    const part = `Owner: ${clip(user ?? '', 1500)}\nYou: ${clip(agent ?? '(no answer)', 1500)}`
    if (used + part.length > RECAP_CHARS && parts.length) break
    parts.unshift(part)
    used += part.length
  }
  if (!parts.length) return ''
  return `This task continues an earlier conversation that could not be reloaded. A recap of it:\n\n${parts.join('\n\n')}\n\nThe new request follows.\n\n`
}

/** Model ids and labels come exclusively from ACP session state. */
export function sessionModels(response) {
  const option = response?.configOptions?.find(item => item.category === 'model' && item.type === 'select')
  if (option) {
    const values = (option.options ?? []).flatMap(item => Array.isArray(item.options) ? item.options : [item])
    return { configId: option.id, currentModelId: option.currentValue,
      availableModels: values.map(item => ({ id: item.value, name: item.name, ...(item.description ? { description: item.description } : {}) })) }
  }
  return response?.models ? { ...response.models } : undefined
}

async function selectModel(agent, sessionId, state, requested) {
  if (!requested) return state
  if (!state?.availableModels?.some(item => item.id === requested)) throw new Error('The requested model is not advertised by this agent session: ' + requested)
  if (state.currentModelId === requested) return state
  const request = (method, params) => Promise.race([agent.connection.agent.request(method, params), agent.died])
  if (state.configId) {
    state = sessionModels(await request('session/set_config_option', { sessionId, configId: state.configId, value: requested }))
    if (state?.currentModelId !== requested) throw new Error('The agent did not confirm the requested model')
    return state
  }
  await request('session/set_model', { sessionId, modelId: requested })
  return { ...state, currentModelId: requested }
}

async function discoverModels(spec) {
  const agent = await startAgent(spec, { cwd: HOME })
  let sessionId
  try {
    const response = await Promise.race([agent.connection.agent.request('session/new', { cwd: HOME, mcpServers: [] }), agent.died,
      sleep(60_000, undefined, { ref: false }).then(() => { throw new Error('Agent model discovery timed out') })])
    sessionId = response.sessionId
    const models = sessionModels(response)
    return models ? { models } : {}
  } finally {
    if (sessionId && agent.init.agentCapabilities?.sessionCapabilities?.close) {
      await Promise.race([agent.connection.agent.request('session/close', { sessionId }).catch(() => {}),
        sleep(3000, undefined, { ref: false })])
    }
    await agent.close()
  }
}

export const PRESENTATION_GUIDANCE = `Caboose displays your replies in a native iPhone/iPad chat and gives you the computer's tools.
For an interactive chart, calculator, dashboard or animated widget, return a complete fenced inline-html block containing self-contained HTML with inline CSS, JavaScript and SVG. Use accessible controls and a responsive layout. No external dependencies, network requests, file access, popups or navigation are available inside a widget. Embed required data in the document after obtaining it with your computer tools. Keep each HTML block under 512 KiB. Use text or a downloadable file when a widget does not help.
Link downloadable computer files with Markdown links to absolute /home/caboose/... paths or home-relative paths. Use image Markdown for PNG/JPEG previews. Caboose authenticates these file previews; never include credentials in an artifact.
An interactive widget may call window.Caboose.compose(message) to propose a follow-up in the native composer. This does not send it or run tools; the owner reviews and sends it. Describe the proposed action clearly on the control. Use the agent's computer tools for actual work, and report real outcomes.`

export class Task {
  constructor(dir) {
    this.dir = dir
    this.inbox = join(dir, 'inbox')
    this.approvals = join(dir, 'approvals')
    this.transcript = new Transcript(join(dir, 'transcript.jsonl'))
    this.normaliser = new Normaliser(this.transcript, new Draft(this.transcript, join(dir, 'draft.json')))
    this.agent = null
    this.sessionId = null
    this.recap = false
    this.turn = null
    this.cancelling = false
    this.waiting = new Map()
    this.log = createWriteStream(join(dir, 'agent.log'), { flags: 'a' })
  }

  async load() {
    const config = JSON.parse(await readFile(join(this.dir, 'task.json'), 'utf8'))
    this.spec = readSpec(config.agent)
    this.requestedModel = config.model
    this.cwd = typeof config.cwd === 'string' && isAbsolute(config.cwd) ? config.cwd : this.dir
    this.agentTools = config.agentTools === true && typeof config.profileId === 'string' && existsSync(AGENT_TOOLS)
    this.profileInstructions = ''
    if (config.profileId !== undefined) {
      if (typeof config.profileId !== 'string' || !/^[0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12}$/.test(config.profileId)) throw new Error('Invalid profile id')
      this.profileInstructions = await readBoundedFile(join(this.dir, 'profile-instructions.txt'), 400_000)
    }
    this.craftServers = Array.isArray(config.craftServers) ? config.craftServers.filter(server =>
      server && typeof server.name === 'string' && /^caboose-[a-z0-9.-]+$/.test(server.name) &&
      typeof server.command === 'string' && /^[a-zA-Z0-9._-]+$/.test(server.command) &&
      Array.isArray(server.args) && server.args.every(arg => typeof arg === 'string' && /^[a-zA-Z0-9._-]+$/.test(arg))
    ).map(server => ({ name: server.name, command: server.command, args: server.args, env: [] })) : []
    this.approvalMode = config.approvals === 'ask' ? 'ask' : 'auto'
    this.idleMs = Number.isSafeInteger(config.idleMs) && config.idleMs >= 0 ? config.idleMs : DEFAULT_IDLE_MS
  }

  /** Inbox entries, cancels first, then prompts in turn order. Names starting with "." are being written. */
  async entries() {
    const names = (await readdir(this.inbox).catch(() => [])).filter(name => name.endsWith('.json') && !name.startsWith('.'))
    return names.sort((a, b) => (a.startsWith('cancel') === b.startsWith('cancel') ? a.localeCompare(b) : a.startsWith('cancel') ? -1 : 1))
  }

  async take(name) {
    const path = join(this.inbox, name)
    const text = await readBoundedFile(path, 262144).catch(error => { if (error.code === 'ENOENT') return undefined; throw error })
    if (text === undefined) return undefined
    let message
    try { message = JSON.parse(text) } catch { throw new Error('Invalid inbox JSON') }
    if (message?.type === 'prompt') {
      if (!Number.isSafeInteger(message.turn) || message.turn < 1 || message.turn > 999999
          || typeof message.text !== 'string' || !message.text.trim() || message.text.length > 32000
          || (message.deliveryId !== undefined && (typeof message.deliveryId !== 'string' || !/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/.test(message.deliveryId)))
          || (message.attachments !== undefined && (!Array.isArray(message.attachments) || message.attachments.length > 4
            || message.attachments.some(file => !file || typeof file.path !== 'string' || !isAbsolute(file.path) || file.path.length > 1024
              || typeof file.name !== 'string' || file.name.length > 255 || (file.mimeType !== undefined && (typeof file.mimeType !== 'string' || file.mimeType.length > 255)))))) throw new Error('Invalid prompt message')
      const receipts = join(this.dir, 'receipts')
      await mkdir(receipts, { recursive: true })
      await syncDirectory(this.dir)
      const receiptPath = join(receipts, `${String(message.turn).padStart(6, '0')}.json`)
      // Exclusive durable claim precedes unlink and every ACP call. An existing claim is
      // never rerun, even if the previous runner died before writing its first user event.
      let handle
      try { handle = await open(receiptPath, 'wx', 0o600) } catch (error) {
        if (error.code !== 'EEXIST') throw error
        const prior = await readBoundedFile(receiptPath, 131072).then(text => JSON.parse(text)).catch(() => undefined)
        if (prior?.state === 'completed' && prior.turn === message.turn && prior.deliveryId === (message.deliveryId ?? null)) {
          await unlink(path); await syncDirectory(this.inbox); return undefined
        }
        throw new Error(`Turn ${message.turn} has an existing claim without a confirmed result; delivery is uncertain and is not replayed.`)
      }
      try {
        await handle.writeFile(JSON.stringify({ turn: message.turn, deliveryId: message.deliveryId ?? null, state: 'claimed' }))
        await handle.sync()
      } finally { await handle.close() }
      await syncDirectory(receipts)
    }
    await unlink(path)
    await syncDirectory(this.inbox)
    return message
  }

  /** The next prompt, or undefined once `waitMs` passes with none. Cancels between turns do nothing. */
  async nextPrompt(waitMs) {
    const deadline = Date.now() + waitMs
    for (;;) {
      for (const name of await this.entries()) {
        const message = await this.take(name)
        if (message?.type === 'prompt' && typeof message.text === 'string' && Number.isSafeInteger(message.turn)) return message
      }
      if (Date.now() >= deadline) return undefined
      await sleep(Math.min(POLL_MS, Math.max(1, deadline - Date.now())))
    }
  }

  async run() {
    await this.load()
    await mkdir(this.approvals, { recursive: true })
    let message = await this.nextPrompt(STARTUP_WAIT_MS)
    while (message) {
      const keepGoing = await this.runTurn(message)
      // Flush the terminal event before acknowledging completion. A crash or failed fsync
      // leaves a claim, which recovery reports as uncertain instead of repeating effects.
      await this.transcript.flushed()
      if (this.interrupted) throw new Error('Runner interrupted')
      if (this.transcript.error) throw this.transcript.error
      const transcript = await open(join(this.dir, 'transcript.jsonl'), 'r')
      try { await transcript.sync() } finally { await transcript.close() }
      await writeJson(join(this.dir, 'receipts', `${String(message.turn).padStart(6, '0')}.json`), {
        turn: message.turn, deliveryId: message.deliveryId ?? null, state: 'completed', result: this.transcript.lastResult,
      })
      if (!keepGoing) break
      message = await this.nextPrompt(this.idleMs)
    }
    await this.shutdown()
  }

  async shutdown() {
    this.normaliser.live = false
    await this.agent?.close()
    this.agent = null
    await this.transcript.flushed()
    await new Promise(resolvePromise => this.log.end(resolvePromise))
  }

  /** Starts the agent if it is not running, then opens or reopens the task's session. */
  async ensureSession() {
    if (this.agent && this.sessionId) { await this.applyModel(); return }
    if (!this.agent) {
      const agent = await startAgent(this.spec, {
        cwd: this.cwd, log: this.log,
        handlers: { update: params => this.onUpdate(params), permission: params => this.onPermission(params) },
      })
      this.agent = agent
      agent.died.catch(() => {
        if (this.agent !== agent) return
        this.agent = null
        this.sessionId = null
      })
    }
    // Requests go to this agent process; if it dies they fail with its exit, not a null reference.
    const agent = this.agent
    const caps = agent.init.agentCapabilities ?? {}
    const mcpServers = existsSync(DESKTOP_MCP)
      ? [{ name: 'caboose-desktop', command: process.execPath, args: [DESKTOP_MCP], env: seatEnv() }]
      : []
    if (this.agentTools) mcpServers.push({ name: 'caboose-agent-tools', command: process.execPath, args: [AGENT_TOOLS, this.dir], env: [] })
    mcpServers.push(...this.craftServers)
    const previous = (await readFile(join(this.dir, 'session'), 'utf8').catch(() => '')).trim()
    const request = (method, params) => Promise.race([agent.connection.agent.request(method, params), agent.died])
    let continuity = 'new'
    let response
    if (previous) {
      try {
        if (caps.sessionCapabilities?.resume) {
          response = await request('session/resume', { sessionId: previous, cwd: this.cwd, mcpServers })
          continuity = 'resume'
        } else if (caps.loadSession) {
          // The agent replays the conversation as session updates; the transcript already has it.
          this.normaliser.live = false
          response = await request('session/load', { sessionId: previous, cwd: this.cwd, mcpServers })
          continuity = 'load'
        }
      } catch (error) {
        if (isAuthRequired(error)) throw error
        response = undefined
        this.transcript.write({ type: 'notice', text: `The earlier session could not be reopened (${errorMessage(error)}); starting a new one.` })
      }
      if (continuity !== 'new') this.sessionId = previous
    }
    if (!this.sessionId) {
      response = await request('session/new', { cwd: this.cwd, mcpServers })
      this.sessionId = response.sessionId
      continuity = previous ? 'recap' : 'new'
      this.recap = Boolean(previous)
      await writeFile(join(this.dir, 'session'), this.sessionId)
    }
    this.models = sessionModels(response)
    await this.applyModel()
    this.transcript.write({
      type: 'session', sessionId: this.sessionId, continuity,
      agent: agent.init.agentInfo ?? null,
      modes: response?.modes ?? null,
      configOptions: Array.isArray(response?.configOptions) ? response.configOptions.map(option => ({ id: option.id, name: option.name, currentValue: option.currentValue })) : null,
    })
  }

  async applyModel() {
    const requested = await readFile(join(this.dir, 'requested-model.json'), 'utf8').then(JSON.parse).catch(error => { if (error.code === 'ENOENT') return this.requestedModel; throw error })
    this.requestedModel = requested
    await this.recordModels()
    this.models = await selectModel(this.agent, this.sessionId, this.models, requested)
    await this.recordModels()
  }

  recordModels() {
    const state = { ...(this.requestedModel ? { requestedModel: this.requestedModel } : {}), ...(this.models ? { models: this.models } : {}) }
    this.modelWrite = (this.modelWrite ?? Promise.resolve()).catch(() => {}).then(async () => {
      await writeJson(join(this.dir, 'models.json'), state)
      const text = JSON.stringify(state)
      if (text !== this.lastModelState && text !== '{}') await this.transcript.write({ type: 'models', ...state })
      this.lastModelState = text
    })
    return this.modelWrite
  }

  onUpdate(params) {
    if (params?.sessionId !== this.sessionId) return
    if (params.update?.sessionUpdate === 'config_option_update') {
      this.models = sessionModels(params.update)
      void this.recordModels().catch(error => console.error(errorMessage(error)))
    }
    this.normaliser.update(params.update)
  }

  async onPermission(params) {
    const known = this.normaliser.tool(params.toolCall?.toolCallId) ?? {}
    const call = { ...known, ...Object.fromEntries(Object.entries(params.toolCall ?? {}).filter(([, value]) => value !== null && value !== undefined)) }
    const options = Array.isArray(params.options) ? params.options : []
    const summary = describeToolCall(call)
    // Once the owner has cancelled the turn, nothing more is allowed in it.
    if (this.cancelling) return { outcome: { outcome: 'cancelled' } }
    if (this.approvalMode === 'auto') {
      const option = chooseOption(options, { allow: true }) ?? options[0]
      if (!option) return { outcome: { outcome: 'cancelled' } }
      this.transcript.write({ type: 'permission', requestId: null, tool: call.title ?? 'Tool', summary, optionId: option.optionId, kind: option.kind, auto: true })
      return { outcome: { outcome: 'selected', optionId: option.optionId } }
    }
    const requestId = randomUUID()
    const request = {
      tool: String(call.title ?? call.kind ?? 'Tool').slice(0, 200), kind: call.kind ?? 'other', summary,
      input: preview(call.rawInput ?? {}),
      options: options.map(option => ({ id: option.optionId, name: option.name, kind: option.kind })),
      toolCallId: call.toolCallId ?? null,
      requestedAt: new Date().toISOString(),
    }
    await writeJson(join(this.approvals, `${requestId}.json`), request)
    this.transcript.write({ type: 'permission', requestId, tool: request.tool, summary })
    const decision = await this.waitForDecision(requestId)
    if (!decision) {
      this.transcript.write({ type: 'permission_resolved', requestId, outcome: 'cancelled' })
      return { outcome: { outcome: 'cancelled' } }
    }
    const option = chooseOption(options, decision)
    this.transcript.write({
      type: 'permission_resolved', requestId, outcome: option ? 'selected' : 'cancelled', allow: decision.allow,
      ...(option ? { optionId: option.optionId, kind: option.kind } : {}),
      ...(decision.message ? { message: decision.message } : {}),
    })
    return option ? { outcome: { outcome: 'selected', optionId: option.optionId } } : { outcome: { outcome: 'cancelled' } }
  }

  /** Resolves the owner's decision { allow, message?, optionId? }, or null when the turn is cancelled. */
  waitForDecision(requestId) {
    return new Promise(resolvePromise => {
      const path = join(this.approvals, `${requestId}.decision`)
      let done = false
      const finish = value => {
        if (done) return
        done = true
        clearInterval(timer)
        this.waiting.delete(requestId)
        resolvePromise(value)
      }
      const timer = setInterval(async () => {
        const text = await readFile(path, 'utf8').catch(() => undefined)
        if (text === undefined || done) return
        let decision
        try { decision = JSON.parse(text) } catch { decision = { allow: false } }
        finish(decision?.cancelled ? null : { allow: decision?.allow === true, ...(typeof decision?.optionId === 'string' ? { optionId: decision.optionId } : {}), ...(typeof decision?.message === 'string' ? { message: decision.message.slice(0, 2000) } : {}) })
      }, POLL_MS)
      this.waiting.set(requestId, () => finish(null))
    })
  }

  /** Answers every waiting permission request "cancelled", and marks its file answered for the host. */
  async cancelWaiting() {
    for (const [requestId, cancel] of [...this.waiting]) {
      await writeJson(join(this.approvals, `${requestId}.decision`), { allow: false, cancelled: true }).catch(() => {})
      cancel()
    }
  }

  async promptBlocks(message) {
    const caps = this.agent.init.agentCapabilities?.promptCapabilities ?? {}
    let text = message.text
    if (this.recap) {
      const lines = (await readFile(join(this.dir, 'transcript.jsonl'), 'utf8').catch(() => '')).split('\n')
      text = recapFrom(lines, message.turn) + text
    }
    const blocks = [{ type: 'text', text: PRESENTATION_GUIDANCE }, ...(this.profileInstructions ? [{ type: 'text', text: this.profileInstructions }] : []), { type: 'text', text }]
    for (const file of Array.isArray(message.attachments) ? message.attachments : []) {
      if (typeof file?.path !== 'string' || !isAbsolute(file.path)) continue
      const info = await stat(file.path).catch(() => undefined)
      if (!info?.isFile()) continue
      const name = typeof file.name === 'string' && file.name ? file.name : basename(file.path)
      const extension = name.slice(name.lastIndexOf('.')).toLowerCase()
      const mimeType = typeof file.mimeType === 'string' && file.mimeType ? file.mimeType : IMAGE_TYPES.get(extension)
      const uri = pathToFileURL(file.path).href
      if (caps.image && mimeType && [...IMAGE_TYPES.values()].includes(mimeType) && info.size <= MAX_IMAGE_BYTES) {
        blocks.push({ type: 'image', mimeType, data: (await readFile(file.path)).toString('base64'), uri })
      } else {
        blocks.push({ type: 'resource_link', uri, name, ...(mimeType ? { mimeType } : {}), size: info.size })
      }
    }
    return blocks
  }

  /** Runs one prompt turn to its end. Returns false when the runner should stop (signed out). */
  async runTurn(message) {
    this.turn = message.turn
    if (this.agentTools) await writeFile(join(this.dir, 'tool-turn'), String(message.turn), { mode: 0o600 })
    await this.transcript.write({ type: 'user', turn: message.turn, text: clip(message.text, 32_000),
      ...(Array.isArray(message.attachments) && message.attachments.length ? { attachments: message.attachments.map(file => file?.path).filter(path => typeof path === 'string') } : {}) })
    let cancelled = false
    let watcher
    let agent
    this.cancelling = false
    try {
      await this.ensureSession()
      agent = this.agent
      const blocks = await this.promptBlocks(message)
      const note = this.recap ? `${this.spec.name} cannot reload conversations, so this turn started a new session with a recap of the earlier ones.` : ''
      this.recap = false
      this.normaliser.begin(message.turn)
      const prompt = this.agent.connection.agent.request('session/prompt', { sessionId: this.sessionId, prompt: blocks })
      let forceStop
      const forced = new Promise(resolvePromise => { forceStop = resolvePromise })
      watcher = setInterval(async () => {
        if (cancelled) return
        for (const name of await this.entries()) {
          if (!name.startsWith('cancel')) continue
          await this.take(name)
          if (cancelled) continue
          cancelled = true
          this.cancelling = true
          await this.agent?.connection.agent.notify('session/cancel', { sessionId: this.sessionId }).catch(() => {})
          await this.cancelWaiting()
          // An agent that ignores session/cancel is stopped; a later reply starts it again.
          setTimeout(() => forceStop({ stopReason: 'cancelled', forced: true }), CANCEL_GRACE_MS).unref()
        }
      }, POLL_MS)
      let response
      try {
        response = await Promise.race([prompt, forced, this.agent.died])
      } catch (error) {
        if (!cancelled) throw error
        response = { stopReason: 'cancelled' }
      }
      await this.modelWrite
      if (response.forced) { await this.agent?.close(); this.agent = null; this.sessionId = null }
      const stopReason = cancelled ? 'cancelled' : response.stopReason
      const last = this.normaliser.end()
      const summary = clip([note, last || stopSummary(stopReason)].filter(Boolean).join('\n\n'), MAX_SUMMARY)
      await this.transcript.write({ type: 'turn_end', turn: message.turn, stopReason, summary })
      return true
    } catch (caught) {
      if (this.interrupted) throw caught
      let error = caught
      if (agent && !isAuthRequired(error) && !(error instanceof AgentExited)) error = await agent.exitError(1000) ?? error
      this.normaliser.end()
      if (isAuthRequired(error)) {
        const methods = this.agent?.init?.authMethods ?? []
        await this.transcript.write({ type: 'auth_required', turn: message.turn, message: clip(errorMessage(error), MAX_SUMMARY), authMethods: publicAuthMethods(methods) })
        return false
      }
      await this.transcript.write({ type: 'turn_failed', turn: message.turn, message: clip(errorMessage(error), MAX_SUMMARY), ...(error instanceof AgentExited ? { uncertain: true } : {}) })
      if (!this.agent || error instanceof AgentExited) { await this.agent?.close(); this.agent = null; this.sessionId = null }
      return true
    } finally {
      clearInterval(watcher)
      // A request the agent left waiting does not outlive its turn.
      await this.cancelWaiting()
      this.cancelling = false
      this.turn = null
      if (this.agentTools) await unlink(join(this.dir, 'tool-turn')).catch(() => {})
    }
  }

  async fail(error) {
    if (this.turn !== null) await this.transcript.write({ type: 'turn_failed', turn: this.turn, message: clip(errorMessage(error), MAX_SUMMARY) })
  }
}

// ---------------------------------------------------------------------------------------------
// Install, probe and sign-in.

function decodeSpec(argument) {
  if (!argument) throw new Error('missing spec')
  return JSON.parse(Buffer.from(argument, 'base64').toString('utf8'))
}

async function prefetch(spec) {
  const env = { ...process.env, ...spec.env }
  if (spec.distribution === 'npx') {
    // The same package spec `npx -y` runs, so its cache entry is the one a task uses.
    await exec('npm', ['exec', '--yes', `--package=${spec.package}`, '--', 'node', '-e', ''], { cwd: HOME, env })
  } else if (spec.distribution === 'uvx') {
    await exec('uvx', ['--from', spec.package, 'python', '-c', ''], { cwd: HOME, env })
  } else {
    await ensureBinary(spec)
    // Older versions are not needed once this one is in place.
    for (const entry of await readdir(join(AGENTS_DIR, spec.id), { withFileTypes: true }).catch(() => [])) {
      if (entry.isDirectory() && entry.name !== spec.version) await rm(join(AGENTS_DIR, spec.id, entry.name), { recursive: true, force: true })
    }
  }
}

async function probe(spec) {
  const agent = await startAgent(spec, { cwd: HOME })
  await agent.close()
  return agent.init
}

async function install(spec) {
  await prefetch(spec)
  let init
  let probeError
  try { init = await probe(spec) } catch (error) { probeError = errorMessage(error) }
  await writeJson(join(AGENTS_DIR, spec.id, 'installed.json'), { spec, version: spec.version, installedAt: new Date().toISOString() })
  return { installed: { version: spec.version }, signIn: publicAuthMethods(init?.authMethods), ...(probeError ? { probeError } : {}) }
}

/**
 * Runs one sign-in method, `on` the phone or the owner's display. An "agent" method is ACP
 * `authenticate` (the agent opens its sign-in page itself); a "terminal" method runs the
 * agent's own program with the method's arguments and environment in a terminal. On the
 * phone the terminal is a session of the terminal service that the app attaches to, and any
 * page the sign-in opens is handed to the app rather than a browser here; on the display it
 * is a terminal window and the page opens in the computer's browser.
 *
 * Each sign-in is one `attempt` (a UUID the host chooses; one is made up when the spec has
 * none). Starting replaces the agent's running attempt, and every record of progress is
 * written only while this attempt is still the agent's, all under the agent's sign-in lock;
 * a runner whose attempt was replaced or cancelled stops. Progress goes to
 * agents/<id>/sign-in.json, with `attempt`, `pid`, `on`, and on the phone the `url` of the
 * page to show and the `terminal` session.
 */
async function signIn({ agent, methodId, env: ownerEnv = {}, on = 'display', attempt = randomUUID() }) {
  const spec = readSpec(agent)
  if (typeof methodId !== 'string' || !methodId) throw new Error('methodId is required')
  if (on !== 'phone' && on !== 'display') throw new Error('on must be "phone" or "display"')
  if (typeof attempt !== 'string' || !ATTEMPT.test(attempt)) throw new Error('attempt must be a UUID')
  const dir = join(AGENTS_DIR, spec.id)
  const status = join(dir, 'sign-in.json')
  const startedAt = new Date().toISOString()
  const progress = { on, attempt, pid: process.pid }
  const record = (state, extra = {}) => ({ methodId, status: state, startedAt, ...progress, ...extra, ...(state !== 'running' ? { finishedAt: new Date().toISOString() } : {}) })
  // Replacing the running attempt and recording this one are one step.
  await withSignInLock(dir, async () => {
    const current = await readJson(status)
    await readPause()
    if (current?.status === 'running') await stopRunner(current, dir)
    await writeJson(status, record('running'))
  })
  /**
   * Records progress while this attempt is still the agent's running sign-in; resolves false
   * once it is not (replaced, cancelled, or already finished), so nothing is written over it.
   */
  const fenced = (state, extra) => withSignInLock(dir, async () => {
    const current = await readJson(status)
    await readPause()
    if (current?.attempt !== attempt || current.status !== 'running') return false
    await writeJson(status, record(state, extra))
    return true
  })
  // Everything this attempt writes besides sign-in.json is its own, so cleaning up after it
  // never touches another attempt's files.
  const work = attemptDir(dir, attempt)
  await mkdir(work, { recursive: true })
  const pages = join(work, 'pages')
  let started
  let session
  /** This attempt was replaced or cancelled: leave nothing of it running. */
  const abandon = async () => {
    if (session) await terminalRequest(`/hangup?session=${session}`).catch(() => {})
    await started?.close().catch(() => {})
    await rm(work, { recursive: true, force: true })
    process.exit(1)
  }
  const report = async (state, extra) => { if (!await fenced(state, extra)) await abandon() }
  const env = on === 'phone' ? await pageCommands(work, pages) : displayEnv(ownerEnv)
  const unset = on === 'phone' ? DESKTOP_VARS : []
  const watcher = on === 'phone' ? watchPages(pages, url => { progress.url = url; return report('running') }) : undefined
  try {
    started = await startAgent(spec, { cwd: HOME, env, unset })
    const method = (started.init.authMethods ?? []).find(item => item?.id === methodId)
    if (!method) throw new Error(`${spec.name} has no sign-in method "${methodId}"`)
    if (method.type === 'terminal') {
      await started.close()
      started = undefined
      const code = on === 'phone'
        ? await runOnPhone(spec, method, env, work, id => { session = id; progress.terminal = id; return report('running') })
        : await runInTerminal(spec, method, env, work)
      if (code !== 0) throw new Error(code === null ? 'The sign-in terminal closed before it finished.' : `The sign-in command exited with code ${code}.`)
      // Reinitialize, as the protocol asks after a terminal sign-in, and keep what it reports.
      await probe(spec)
    } else if (method.type === undefined || method.type === null || method.type === 'agent') {
      await Promise.race([
        started.connection.agent.request('authenticate', { methodId }),
        started.died,
        sleep(SIGN_IN_TIMEOUT_MS).then(() => { throw new Error('Sign-in did not finish within 30 minutes.') }),
      ])
    } else {
      throw new Error(`Sign-in methods of type "${method.type}" are not supported.`)
    }
    await watcher?.stop()
    if (!await fenced('succeeded')) process.exitCode = 1
  } catch (error) {
    await watcher?.stop()
    await fenced('failed', { message: clip(errorMessage(error), 1000) })
    process.exitCode = 1
  } finally {
    await started?.close()
    await rm(work, { recursive: true, force: true })
  }
}

/** The directory of one attempt's own files: its page list, browser commands and scripts. */
function attemptDir(dir, attempt) { return join(dir, 'attempts', attempt) }

/**
 * Cancels the agent's running sign-in if it is attempt `attempt`: stops its runner and
 * terminal session and records it as failed. A different (newer) attempt is left alone.
 * Resolves whether it was cancelled.
 */
async function cancelSignIn(id, attempt) {
  if (!AGENT_ID.test(id ?? '')) throw new Error('invalid agent id')
  if (typeof attempt !== 'string' || !ATTEMPT.test(attempt)) throw new Error('attempt must be a UUID')
  const path = join(AGENTS_DIR, id, 'sign-in.json')
  return withSignInLock(join(AGENTS_DIR, id), async () => {
    const current = await readJson(path)
    await readPause()
    if (current?.status !== 'running' || current.attempt !== attempt) return false
    await stopRunner(current, join(AGENTS_DIR, id))
    const { pid: _pid, ...rest } = current
    await writeJson(path, { ...rest, status: 'failed', message: 'Sign-in cancelled.', finishedAt: new Date().toISOString() })
    return true
  })
}

/**
 * Stops a running attempt as recorded: its runner's process group (which holds the agent),
 * only after checking that the pid is still the runner of that attempt, and its terminal
 * session. A runner that ignores SIGTERM for three seconds is killed. Once its runner is gone,
 * the attempt's own directory in the agent's `dir` goes too.
 */
async function stopRunner(current, dir) {
  const pid = current.pid
  const owns = () => runsAttempt(pid, current.attempt)
  const ours = Number.isInteger(pid) && pid > 1 && pid !== process.pid
  if (ours && await owns()) {
    signalGroup(pid, 'SIGTERM')
    for (let wait = 0; wait < 30 && await owns(); wait++) await sleep(100)
    if (await owns()) signalGroup(pid, 'SIGKILL')
    for (let wait = 0; wait < 10 && await owns(); wait++) await sleep(100)
  }
  if (typeof current.terminal === 'string' && TERMINAL_SESSION.test(current.terminal)) {
    await terminalRequest(`/hangup?session=${current.terminal}`).catch(() => {})
  }
  if (typeof current.attempt === 'string' && ATTEMPT.test(current.attempt) && !(ours && await owns())) {
    await rm(attemptDir(dir, current.attempt), { recursive: true, force: true })
  }
}

function signalGroup(pid, signal) {
  // The runner starts with setsid, so its pid is its process group.
  try { process.kill(-pid, signal) } catch { try { process.kill(pid, signal) } catch {} }
}

/**
 * Whether `pid` is the sign-in runner of `attempt`, read from its own command line, so a
 * reused pid, or the runner of another attempt, is never signalled. A record from a runner
 * that predates attempts has none, and matches a runner started without one.
 */
async function runsAttempt(pid, attempt) {
  const proc = await readFile(`/proc/${pid}/cmdline`, 'utf8').catch(() => undefined)
  const args = proc !== undefined ? proc.split('\0') : (await exec('ps', ['-o', 'command=', '-p', String(pid)]).catch(() => '')).trim().split(/\s+/)
  const at = args.indexOf('sign-in')
  if (at < 1 || !args.slice(0, at).some(arg => arg.includes('caboose-agentd'))) return false
  try { return (decodeSpec(args[at + 1]).attempt ?? null) === (attempt ?? null) } catch { return false }
}

// ---------------------------------------------------------------------------------------------
// The sign-in lock.

const ATTEMPT = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/
const TERMINAL_SESSION = /^[0-9a-f]{32}$/
const LOCK_WAIT_MS = 90_000
/** Longer than anything done holding the lock: stopping a runner, or delivering a callback. */
const LOCK_STALE_MS = 120_000
/** How long a lock file may stay empty while its creator writes it. */
const LOCK_WRITE_MS = 5_000

/**
 * Runs `work` holding the agent's sign-in lock (agents/<id>/sign-in.lock), so starting,
 * replacing, cancelling, recording progress and delivering a callback never interleave,
 * across processes. The lock names its holder's pid; one whose holder has died, that was
 * never written, or that is older than LOCK_STALE_MS is taken over. Taking over goes through
 * a second lock, so only one process does it, and only while the lock is still the one it
 * judged stale.
 */
async function withSignInLock(dir, work) {
  await mkdir(dir, { recursive: true })
  const lock = join(dir, 'sign-in.lock')
  const token = randomUUID()
  const deadline = Date.now() + LOCK_WAIT_MS
  while (!await createLock(lock, { pid: process.pid, token, at: Date.now() })) {
    const held = await readFile(lock, 'utf8').catch(() => undefined)
    const info = await stat(lock).catch(() => undefined)
    if (held !== undefined && info && isStaleLock(held, info.mtimeMs)) await takeOver(lock, held)
    if (Date.now() > deadline) throw new Error('Another sign-in change for this agent did not finish. Try again.')
    await sleep(20)
  }
  try {
    return await work()
  } finally {
    // Only our own: a lock taken over from us is someone else's now.
    if ((await readJson(lock))?.token === token) await rm(lock, { force: true })
  }
}

/**
 * Waits `CABOOSE_AGENTD_SIGN_IN_PAUSE_MS` between reading the sign-in state and acting on
 * it, under the lock, so tests can overlap operations at exactly the point a race would hurt.
 */
function readPause() {
  const ms = Number(process.env.CABOOSE_AGENTD_SIGN_IN_PAUSE_MS)
  return ms > 0 ? sleep(ms) : undefined
}

/** Creates `path` exclusively with `holder` in it; false when it exists. */
async function createLock(path, holder) {
  let handle
  try { handle = await open(path, 'wx', 0o600) } catch (error) {
    if (error.code === 'EEXIST') return false
    throw error
  }
  try { await handle.writeFile(JSON.stringify(holder)); await handle.sync() } finally { await handle.close() }
  return true
}

export function isStaleLock(text, modifiedMs, now = Date.now()) {
  let holder
  try { holder = JSON.parse(text) } catch { return now - modifiedMs > LOCK_WRITE_MS }
  if (!Number.isInteger(holder?.pid) || holder.pid < 1 || !isAlive(holder.pid)) return true
  return !(now - holder.at <= LOCK_STALE_MS)
}

function isAlive(pid) {
  try { process.kill(pid, 0); return true } catch (error) { return error.code === 'EPERM' }
}

async function takeOver(lock, judged) {
  const guard = `${lock}.takeover`
  if (!await createLock(guard, { pid: process.pid, at: Date.now() })) {
    // A process that died taking over leaves this behind; taking over is quick.
    const info = await stat(guard).catch(() => undefined)
    if (info && Date.now() - info.mtimeMs > LOCK_WRITE_MS) await rm(guard, { force: true })
    return
  }
  try {
    if (await readFile(lock, 'utf8').catch(() => undefined) === judged) await rm(lock, { force: true })
  } finally {
    await rm(guard, { force: true })
  }
}

// ---------------------------------------------------------------------------------------------
// Signing in on the phone.

/** Variables that point a program at the owner's desktop. A sign-in on the phone has none, so nothing opens there. */
const DESKTOP_VARS = ['DISPLAY', 'WAYLAND_DISPLAY', 'XDG_CURRENT_DESKTOP', 'XDG_SESSION_DESKTOP', 'DESKTOP_SESSION', 'XDG_SESSION_TYPE',
  'GNOME_DESKTOP_SESSION_ID', 'KDE_FULL_SESSION']
/** Commands programs run to open a web page. */
const BROWSER_COMMANDS = ['xdg-open', 'x-www-browser', 'www-browser', 'sensible-browser', 'gnome-www-browser']
const TERMINAL_URL = `http://127.0.0.1:${Number(process.env.CABOOSE_TERMINAL_PORT) || 14701}`
const TERMINAL_TOKEN = process.env.CABOOSE_TERMINAL_TOKEN_FILE ?? '/run/caboose/display-token'
const LOOPBACK = new Set(['localhost', '127.0.0.1', '[::1]'])
const MAX_URL = 8192

/**
 * Writes, in the attempt's directory `work`, the commands a sign-in on the phone opens web
 * pages with: each appends the pages it is given to `pages`, for the app to show. Resolves the
 * variables that make a sign-in use them: PATH with them first, and BROWSER.
 */
export async function pageCommands(work, pages) {
  const bin = join(work, 'bin')
  await mkdir(bin, { recursive: true })
  const script = [
    '#!/bin/sh',
    '# Written by caboose-agentd: hands a sign-in page to the phone instead of opening it here.',
    'for page in "$@"; do',
    `  case "$page" in http://*|https://*) printf '%s\\n' "$page" >> ${shellQuote(pages)} ;; esac`,
    'done',
    '',
  ].join('\n')
  for (const name of BROWSER_COMMANDS) {
    await writeFile(join(bin, name), script)
    await chmod(join(bin, name), 0o755)
  }
  return { PATH: `${bin}:${process.env.PATH || '/usr/local/bin:/usr/bin:/bin'}`, BROWSER: join(bin, 'xdg-open') }
}

/** Calls `onPage` with each new page the sign-in hands over, until stopped. */
function watchPages(path, onPage) {
  let stopped = false
  let last
  const loop = (async () => {
    while (!stopped) {
      const page = latestPage(await readFile(path, 'utf8').catch(() => ''))
      if (page && page !== last) {
        last = page
        await onPage(page)
      }
      await sleep(300)
    }
  })()
  return { stop: async () => { stopped = true; await loop } }
}

/** The last web page in a list of pages, one per line. */
export function latestPage(text) {
  return text.split('\n').map(line => line.trim()).filter(isWebPage).at(-1)
}

function isWebPage(value) {
  if (!value || value.length > MAX_URL) return false
  try {
    const url = new URL(value)
    return url.protocol === 'https:' || url.protocol === 'http:'
  } catch { return false }
}

function shellQuote(value) { return `'${String(value).replaceAll("'", `'\\''`)}'` }

/** A request to the computer's terminal service, with the token it checks. */
async function terminalRequest(path) {
  let token
  try { token = await readFile(TERMINAL_TOKEN, 'utf8') } catch (error) { throw new Error(`The computer's terminal service is not available: ${errorMessage(error)}`) }
  let response
  try {
    response = await fetch(`${TERMINAL_URL}${path}`, { headers: { authorization: `Bearer ${token}` }, signal: AbortSignal.timeout(10_000) })
  } catch (error) {
    throw new Error(`The computer's terminal service did not answer: ${errorMessage(error.cause ?? error)}`)
  }
  const body = await response.json().catch(() => ({}))
  if (!response.ok) throw new Error(`The computer's terminal service refused the sign-in: ${body.error ?? `HTTP ${response.status}`}`)
  return body
}

/**
 * Runs a terminal sign-in method in a session of the terminal service, for the app to attach
 * to; `onSession` receives the session id. Its environment goes through a file (mode 0600)
 * the session reads and removes, so keys never appear in a command line. Resolves the exit
 * status, or null when the session ended without one (hung up) or the time ran out. Its
 * files are in the attempt's directory `work`.
 */
async function runOnPhone(spec, method, env, work, onSession) {
  const methodArgs = Array.isArray(method.args) ? method.args.filter(arg => typeof arg === 'string') : []
  const methodEnv = method.env && typeof method.env === 'object' ? Object.fromEntries(Object.entries(method.env).filter(([key, value]) => ENV_NAME.test(key) && typeof value === 'string')) : {}
  const { command, args } = launchCommand(spec, methodArgs)
  const exitFile = join(work, `${randomUUID()}.exit`)
  const envFile = join(work, `${randomUUID()}.env`)
  const vars = { ...spec.env, ...await readEnvFile(spec.id), ...env, ...methodEnv }
  await writeFile(envFile, Object.entries(vars).filter(([key, value]) => ENV_NAME.test(key) && typeof value === 'string')
    .map(([key, value]) => `export ${key}=${shellQuote(value)}`).join('\n') + '\n', { mode: 0o600 })
  const script = join(work, 'phone.sh')
  await writeFile(script, [
    '#!/bin/sh',
    '# Written by caboose-agentd: runs one terminal sign-in method for the phone and records its exit status.',
    'status_file=$1; env_file=$2; shift 2',
    `unset ${DESKTOP_VARS.join(' ')}`,
    '. "$env_file"; rm -f "$env_file"',
    'cd "$HOME" || exit 1',
    '"$@"',
    'code=$?',
    'printf %s "$code" > "$status_file"',
    'exit "$code"',
    '',
  ].join('\n'), { mode: 0o755 })
  try {
    const argv = Buffer.from(JSON.stringify(['/bin/sh', script, exitFile, envFile, command, ...args])).toString('base64url')
    const { session } = await terminalRequest(`/start?cols=80&rows=24&argv=${argv}`)
    if (typeof session !== 'string') throw new Error('The computer\'s terminal service did not start the sign-in.')
    await onSession(session)
    const deadline = Date.now() + SIGN_IN_TIMEOUT_MS
    for (let poll = 1; ; poll++) {
      const text = await readFile(exitFile, 'utf8').catch(() => undefined)
      if (text !== undefined && text.trim() !== '') return Number.parseInt(text, 10)
      if (poll % 10 === 0) {
        const { sessions } = await terminalRequest('/sessions').catch(() => ({ sessions: undefined }))
        if (Array.isArray(sessions) && !sessions.some(item => item?.id === session)) {
          const late = await readFile(exitFile, 'utf8').catch(() => undefined)
          return late ? Number.parseInt(late, 10) : null
        }
      }
      if (Date.now() > deadline) {
        await terminalRequest(`/hangup?session=${session}`).catch(() => {})
        return null
      }
      await sleep(500)
    }
  } finally {
    await rm(exitFile, { force: true })
    await rm(envFile, { force: true })
  }
}

/** An address on the computer's loopback that a sign-in on the phone was sent back to. */
export function loopbackURL(value) {
  let url
  try { url = new URL(value) } catch { throw new Error('That is not a web address.') }
  if (typeof value !== 'string' || value.length > MAX_URL || url.protocol !== 'http:' || !LOOPBACK.has(url.hostname) || !url.port || url.username || url.password) {
    throw new Error('Only an http://localhost:<port> address on the computer can be delivered.')
  }
  return url
}

/**
 * Delivers the page a sign-in on the phone was sent back to. It belongs to the agent's own
 * server on the computer's loopback, so it is fetched here, following redirects that stay on
 * the loopback, within 30 seconds. Only to attempt `attempt` while it is the agent's running
 * sign-in on the phone, holding the sign-in lock throughout, so the attempt cannot be
 * replaced or cancelled meanwhile. Resolves { status }.
 */
async function deliverCallback(id, attempt, value) {
  if (!AGENT_ID.test(id ?? '')) throw new Error('invalid agent id')
  if (typeof attempt !== 'string' || !ATTEMPT.test(attempt)) throw new Error('attempt must be a UUID')
  const start = loopbackURL(value)
  return withSignInLock(join(AGENTS_DIR, id), async () => {
    const current = await readJson(join(AGENTS_DIR, id, 'sign-in.json'))
    await readPause()
    if (current?.status !== 'running' || current.attempt !== attempt || current.on !== 'phone') throw new Error('No sign-in is waiting for this page.')
    return fetchLoopback(start, AbortSignal.timeout(CALLBACK_MS))
  })
}

const CALLBACK_MS = 30_000

async function fetchLoopback(first, signal) {
  let url = first
  let status
  for (let hop = 0; hop < 5; hop++) {
    let response
    try {
      response = await loopbackFetch(url, signal)
    } catch (error) {
      // An agent that has its answer often stops its server before its result page is read.
      if (status !== undefined) return { status }
      throw error
    }
    await response.arrayBuffer().catch(() => {})
    status = response.status
    const location = response.headers.get('location')
    if (status < 300 || status >= 400 || !location) return { status }
    const next = new URL(location, url)
    // A redirect off the computer is the agent showing its own result page.
    if (next.protocol !== 'http:' || !LOOPBACK.has(next.hostname)) return { status }
    url = next
  }
  return { status }
}

async function loopbackFetch(url, signal) {
  // `localhost` is either loopback address, and a server often listens on only one.
  const hosts = url.hostname === 'localhost' ? ['127.0.0.1', '[::1]'] : [url.hostname]
  let failure
  for (const host of hosts) {
    const target = new URL(url)
    target.hostname = host
    try { return await fetch(target, { redirect: 'manual', signal }) } catch (error) { failure = error }
  }
  throw new Error(`Nothing on the computer answered ${url.host}: ${errorMessage(failure?.cause ?? failure)}`)
}

/**
 * Opens a terminal window running the agent's program for a terminal sign-in method, with its
 * files in the attempt's directory `work`; resolves its exit status.
 */
async function runInTerminal(spec, method, env, work) {
  const methodArgs = Array.isArray(method.args) ? method.args.filter(arg => typeof arg === 'string') : []
  const methodEnv = method.env && typeof method.env === 'object' ? Object.fromEntries(Object.entries(method.env).filter(([key, value]) => ENV_NAME.test(key) && typeof value === 'string')) : {}
  const { command, args } = launchCommand(spec, methodArgs)
  const exitFile = join(work, `${randomUUID()}.exit`)
  const script = join(work, 'terminal.sh')
  await writeFile(script, [
    '#!/bin/sh',
    '# Written by caboose-agentd: runs one terminal sign-in method and records its exit status.',
    'status_file=$1; shift',
    '"$@"',
    'code=$?',
    'printf %s "$code" > "$status_file"',
    'echo',
    'if [ "$code" = 0 ]; then echo "Signed in. Press Enter to close this window."; else echo "Sign-in exited with code $code. Press Enter to close this window."; fi',
    'read _ || true',
  ].join('\n'), { mode: 0o755 })
  const terminal = existsSync('/usr/bin/xfce4-terminal')
    ? ['xfce4-terminal', ['--disable-server', `--title=Sign in to ${spec.name}`, '--execute', '/bin/sh', script, exitFile, command, ...args]]
    : ['x-terminal-emulator', ['-e', '/bin/sh', script, exitFile, command, ...args]]
  const child = spawn(terminal[0], terminal[1], { cwd: HOME, env: { ...process.env, ...spec.env, ...await readEnvFile(spec.id), ...env, ...methodEnv }, stdio: 'ignore' })
  const closed = new Promise(resolvePromise => { child.on('exit', () => resolvePromise()); child.on('error', () => resolvePromise()) })
  const deadline = Date.now() + SIGN_IN_TIMEOUT_MS
  let terminalClosed = false
  closed.then(() => { terminalClosed = true })
  try {
    for (;;) {
      const text = await readFile(exitFile, 'utf8').catch(() => undefined)
      if (text !== undefined && text.trim() !== '') return Number.parseInt(text, 10)
      if (terminalClosed) {
        const late = await readFile(exitFile, 'utf8').catch(() => undefined)
        return late ? Number.parseInt(late, 10) : null
      }
      if (Date.now() > deadline) { child.kill(); return null }
      await sleep(500)
    }
  } finally {
    await rm(exitFile, { force: true })
  }
}

async function state() {
  const agents = {}
  for (const entry of await readdir(AGENTS_DIR, { withFileTypes: true }).catch(() => [])) {
    if (!entry.isDirectory() || !AGENT_ID.test(entry.name)) continue
    const dir = join(AGENTS_DIR, entry.name)
    const installed = await readJson(join(dir, 'installed.json'))
    const auth = await readJson(join(dir, 'auth.json'))
    const signIn = await readJson(join(dir, 'sign-in.json'))
    const env = await envNames(entry.name)
    agents[entry.name] = {
      ...(installed?.spec ? { installed: { version: installed.version, spec: installed.spec, installedAt: installed.installedAt } } : {}),
      ...(env.length ? { env } : {}),
      ...(auth ? { authMethods: Array.isArray(auth.authMethods) ? auth.authMethods : [], probedVersion: auth.version, agentInfo: auth.agentInfo ?? null } : {}),
      ...(signIn ? { signInStatus: signIn } : {}),
    }
  }
  // An environment file can come before the agent is ever installed or run.
  for (const file of await readdir(ENV_DIR).catch(() => [])) {
    const id = file.endsWith('.env') ? file.slice(0, -4) : ''
    if (!AGENT_ID.test(id) || agents[id]) continue
    const env = await envNames(id)
    if (env.length) agents[id] = { env }
  }
  return { runner: VERSION, agents }
}

// ---------------------------------------------------------------------------------------------

async function main(argv) {
  const [mode, argument] = argv
  if (mode === 'run') {
    if (!argument || !isAbsolute(argument)) throw new Error('run needs an absolute task directory')
    const task = new Task(argument)
    const stop = async signal => {
      task.interrupted = true
      await task.transcript.write({ type: 'notice', text: 'Runner interrupted; the active turn may have performed external actions. Delivery is uncertain and is not replayed.' }).catch(() => {})
      await task.agent?.close().catch(() => {})
      await task.transcript.flushed()
      process.exit(signal === 'SIGTERM' ? 143 : 130)
    }
    process.once('SIGTERM', () => { void stop('SIGTERM') })
    process.once('SIGINT', () => { void stop('SIGINT') })
    try {
      await task.run()
    } catch (error) {
      await task.fail(error).catch(() => {})
      await task.shutdown().catch(() => {})
      throw error
    }
    return
  }
  if (mode === 'install') return print(await install(readSpec(decodeSpec(argument))))
  if (mode === 'models') return print(await discoverModels(readSpec(decodeSpec(argument))))
  if (mode === 'probe') {
    const init = await probe(readSpec(decodeSpec(argument)))
    return print({ signIn: publicAuthMethods(init.authMethods), agentInfo: init.agentInfo ?? null })
  }
  if (mode === 'sign-in') return signIn(decodeSpec(argument))
  if (mode === 'sign-in-callback') return print(await deliverCallback(argument, argv[2], argv[3]))
  if (mode === 'sign-in-cancel') return print({ cancelled: await cancelSignIn(argument, argv[2]) })
  if (mode === 'state') return print(await state())
  if (mode === 'set-env') {
    let changes
    try { changes = JSON.parse(argv[2] ?? '') } catch { throw new Error('set-env needs { set?, remove? } as JSON') }
    return print({ env: await setEnv(argument, changes) })
  }
  if (mode === '--version') return print({ version: VERSION })
  throw new Error('usage: caboose-agentd run <dir> | install <spec> | probe <spec> | sign-in <spec> | sign-in-callback <id> <attempt> <url> | sign-in-cancel <id> <attempt> | state | set-env <id> <json>')
}

function print(value) { process.stdout.write(JSON.stringify(value) + '\n') }

if (import.meta.url === pathToFileURL(process.argv[1] ?? '').href || process.argv[1]?.endsWith('caboose-agentd.mjs')) {
  // A dying agent can leave a broken pipe behind; it is reported where it matters, not fatal here.
  process.on('unhandledRejection', error => console.error('caboose-agentd:', errorMessage(error)))
  main(process.argv.slice(2)).then(
    () => process.exit(process.exitCode ?? 0),
    error => { console.error(errorMessage(error)); process.exit(1) },
  )
}

