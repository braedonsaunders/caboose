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
//   caboose-agentd sign-in <spec base64>  run one sign-in method on the owner's display
//   caboose-agentd state                  print what is installed and known, as JSON
//   caboose-agentd set-env <id> <json>    change an agent's environment file: { set?, remove? }
import { spawn } from 'node:child_process'
import { createHash, randomUUID } from 'node:crypto'
import { createWriteStream, existsSync, readFileSync } from 'node:fs'
import {
  appendFile, chmod, mkdir, readdir, readFile, realpath, rename, rm, stat, unlink, writeFile,
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
const POLL_MS = Number(process.env.CABOOSE_AGENTD_POLL_MS) || 250
const CANCEL_GRACE_MS = Number(process.env.CABOOSE_AGENTD_CANCEL_GRACE_MS) || 15_000
const INITIALIZE_TIMEOUT_MS = Number(process.env.CABOOSE_AGENTD_INIT_TIMEOUT_MS) || 120_000
const SIGN_IN_TIMEOUT_MS = 30 * 60_000
const DEFAULT_IDLE_MS = 10 * 60_000
/** How long a freshly started runner waits for its first prompt before deciding it was started by mistake. */
const STARTUP_WAIT_MS = 30_000
const MAX_TEXT = 512 * 1024
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

/** The display environment for a GUI on `display`, with the owner's session bus when it exists. */
function displayEnv(display) {
  const env = { DISPLAY: display }
  if (existsSync('/run/user/1000/bus')) Object.assign(env, { XDG_RUNTIME_DIR: '/run/user/1000', DBUS_SESSION_BUS_ADDRESS: 'unix:path=/run/user/1000/bus' })
  return env
}

const CLIENT_CAPABILITIES = {
  // File reads and writes go through Caboose, limited to the home directory.
  fs: { readTextFile: true, writeTextFile: true },
  // Agents run their own commands; Caboose does not host terminals for them.
  terminal: false,
  // Terminal sign-in methods open a terminal window on the owner's display.
  auth: { terminal: true },
}

/**
 * Starts an agent and initializes ACP. `handlers` receives session updates and permission
 * requests. Resolves { connection, init, child, exited, stderrTail(), close() }.
 */
async function startAgent(spec, { cwd, env = {}, handlers = {}, log }) {
  if (spec.distribution === 'binary') await ensureBinary(spec)
  const { command, args } = launchCommand(spec)
  const child = spawn(command, args, { cwd, env: { ...process.env, ...spec.env, ...await readEnvFile(spec.id), ...env }, stdio: ['pipe', 'pipe', 'pipe'] })
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
  return methods.flatMap(method => {
    if (!method || typeof method.id !== 'string' || typeof method.name !== 'string') return []
    const type = method.type === undefined || method.type === null || method.type === 'agent' ? 'agent' : method.type === 'terminal' ? 'terminal' : undefined
    if (!type) return []
    return [{ id: method.id, name: method.name, ...(typeof method.description === 'string' && method.description ? { description: method.description } : {}), type }]
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
  await writeFile(temporary, JSON.stringify(value))
  await rename(temporary, path)
}

async function readJson(path) {
  try { return JSON.parse(await readFile(path, 'utf8')) } catch { return undefined }
}

// ---------------------------------------------------------------------------------------------
// The transcript: one JSON object per line, the same shape for every agent.

class Transcript {
  constructor(path) { this.path = path; this.chain = Promise.resolve() }
  write(event) {
    const line = JSON.stringify({ ...event, at: new Date().toISOString() }) + '\n'
    this.chain = this.chain.then(() => appendFile(this.path, line)).catch(error => console.error('transcript write failed:', error))
    return this.chain
  }
  flushed() { return this.chain }
}

function clip(text, max = MAX_TEXT) { return text.length > max ? `${text.slice(0, max - 1)}…` : text }

/**
 * Turns ACP session updates into transcript events: message and thought chunks coalesced per
 * message, tool calls and their status changes, plans, mode changes, and the turn's usage.
 */
export class Normaliser {
  constructor(transcript) {
    this.transcript = transcript
    this.tools = new Map()
    this.live = false
    this.buffers = { text: null, thought: null }
    this.lastText = ''
    this.usage = null
  }

  begin() { this.live = true; this.lastText = ''; this.usage = null }

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
  }

  flushOne(kind) {
    const buffer = this.buffers[kind]
    this.buffers[kind] = null
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

class Task {
  constructor(dir) {
    this.dir = dir
    this.inbox = join(dir, 'inbox')
    this.approvals = join(dir, 'approvals')
    this.transcript = new Transcript(join(dir, 'transcript.jsonl'))
    this.normaliser = new Normaliser(this.transcript)
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
    this.cwd = typeof config.cwd === 'string' && isAbsolute(config.cwd) ? config.cwd : this.dir
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
    const text = await readFile(path, 'utf8').catch(() => undefined)
    await unlink(path).catch(() => {})
    try { return JSON.parse(text) } catch { return undefined }
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
    if (this.agent && this.sessionId) return
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
      ? [{ name: 'caboose-desktop', command: process.execPath, args: [DESKTOP_MCP], env: [{ name: 'CABOOSE_AGENT_DISPLAY', value: process.env.DISPLAY || ':101' }] }]
      : []
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
    this.transcript.write({
      type: 'session', sessionId: this.sessionId, continuity,
      agent: agent.init.agentInfo ?? null,
      modes: response?.modes ?? null,
      configOptions: Array.isArray(response?.configOptions) ? response.configOptions.map(option => ({ id: option.id, name: option.name, currentValue: option.currentValue })) : null,
    })
  }

  onUpdate(params) {
    if (params?.sessionId !== this.sessionId) return
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
    const blocks = [{ type: 'text', text }]
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
    this.transcript.write({ type: 'user', turn: message.turn, text: clip(message.text, 32_000),
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
      this.normaliser.begin()
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
      if (response.forced) { await this.agent?.close(); this.agent = null; this.sessionId = null }
      const stopReason = cancelled ? 'cancelled' : response.stopReason
      const last = this.normaliser.end()
      const summary = clip([note, last || stopSummary(stopReason)].filter(Boolean).join('\n\n'), MAX_SUMMARY)
      await this.transcript.write({ type: 'turn_end', turn: message.turn, stopReason, summary })
      return true
    } catch (caught) {
      let error = caught
      if (agent && !isAuthRequired(error) && !(error instanceof AgentExited)) error = await agent.exitError(1000) ?? error
      this.normaliser.end()
      if (isAuthRequired(error)) {
        const methods = this.agent?.init?.authMethods ?? []
        await this.transcript.write({ type: 'auth_required', turn: message.turn, message: errorMessage(error), authMethods: publicAuthMethods(methods) })
        return false
      }
      await this.transcript.write({ type: 'turn_failed', turn: message.turn, message: clip(errorMessage(error), MAX_SUMMARY) })
      if (!this.agent || error instanceof AgentExited) { await this.agent?.close(); this.agent = null; this.sessionId = null }
      return true
    } finally {
      clearInterval(watcher)
      // A request the agent left waiting does not outlive its turn.
      await this.cancelWaiting()
      this.cancelling = false
      this.turn = null
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
 * Runs one sign-in method on the owner's display. An "agent" method is ACP `authenticate`
 * (the agent opens the browser itself); a "terminal" method opens a terminal window running
 * the agent's own program with the method's arguments and environment. Progress goes to
 * agents/<id>/sign-in.json.
 */
async function signIn({ agent, methodId, display = ':100' }) {
  const spec = readSpec(agent)
  if (typeof methodId !== 'string' || !methodId) throw new Error('methodId is required')
  const dir = join(AGENTS_DIR, spec.id)
  await mkdir(dir, { recursive: true })
  const status = join(dir, 'sign-in.json')
  const startedAt = new Date().toISOString()
  const report = (state, extra = {}) => writeJson(status, { methodId, status: state, startedAt, ...extra, ...(state !== 'running' ? { finishedAt: new Date().toISOString() } : {}) })
  await report('running')
  const env = displayEnv(display)
  let started
  try {
    started = await startAgent(spec, { cwd: HOME, env })
    const method = (started.init.authMethods ?? []).find(item => item?.id === methodId)
    if (!method) throw new Error(`${spec.name} has no sign-in method "${methodId}"`)
    if (method.type === 'terminal') {
      await started.close()
      started = undefined
      const code = await runInTerminal(spec, method, env, dir)
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
    await report('succeeded')
  } catch (error) {
    await report('failed', { message: clip(errorMessage(error), 1000) })
    process.exitCode = 1
  } finally {
    await started?.close()
  }
}

/** Opens a terminal window running the agent's program for a terminal sign-in method; resolves its exit status. */
async function runInTerminal(spec, method, env, dir) {
  const methodArgs = Array.isArray(method.args) ? method.args.filter(arg => typeof arg === 'string') : []
  const methodEnv = method.env && typeof method.env === 'object' ? Object.fromEntries(Object.entries(method.env).filter(([key, value]) => ENV_NAME.test(key) && typeof value === 'string')) : {}
  const { command, args } = launchCommand(spec, methodArgs)
  const exitFile = join(dir, `sign-in-${randomUUID()}.exit`)
  const script = join(dir, 'sign-in.sh')
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
      await task.fail(new Error('Stopped.')).catch(() => {})
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
  if (mode === 'probe') {
    const init = await probe(readSpec(decodeSpec(argument)))
    return print({ signIn: publicAuthMethods(init.authMethods), agentInfo: init.agentInfo ?? null })
  }
  if (mode === 'sign-in') return signIn(decodeSpec(argument))
  if (mode === 'state') return print(await state())
  if (mode === 'set-env') {
    let changes
    try { changes = JSON.parse(argv[2] ?? '') } catch { throw new Error('set-env needs { set?, remove? } as JSON') }
    return print({ env: await setEnv(argument, changes) })
  }
  if (mode === '--version') return print({ version: VERSION })
  throw new Error('usage: caboose-agentd run <dir> | install <spec> | probe <spec> | sign-in <spec> | state | set-env <id> <json>')
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

