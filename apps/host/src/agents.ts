import { randomUUID } from 'node:crypto'
import type { HomeOwnership } from './home.js'
import { decodeBase64, sanitizeFileName, uniqueName, writeGuestFile } from './files.js'
import type { AgentLaunch } from './registry.js'

/**
 * Agent tasks: any Agent Client Protocol (ACP) agent from the registry, run inside the
 * owner's computer as user `caboose` on the agent seat (DISPLAY=:101) by the guest's runner,
 * caboose-agentd. Each task lives in /home/caboose/Agents/<id>/: the host writes task.json
 * and prompts into inbox/, the runner writes an agent-neutral transcript.jsonl and approval
 * requests, and the host tails them into control-socket events. A task outlives a host
 * restart: the directory is the record. See docs/architecture.md § Agents and
 * guest/agentd/README.md for the file protocol.
 */
export type TaskStatus = 'running' | 'paused' | 'succeeded' | 'failed' | 'cancelled'

export type ApprovalMode = 'ask' | 'auto'

/** A way to sign in to an agent, as the agent announced it. */
export interface SignInMethod { id: string; name: string; description?: string; type: 'agent' | 'terminal' }

/** A tool use the agent is waiting on the owner to allow or deny. */
export interface PendingApproval {
  id: string
  tool: string
  summary: string
  /** The choices the agent offered; an answer may name one with `optionId`. */
  options?: Array<{ id: string; name: string; kind: string }>
}

export interface AgentTask {
  id: string
  /** The ACP registry id of the agent. */
  agent: string
  /** The agent's display name from the registry. */
  agentName?: string
  prompt: string
  status: TaskStatus
  startedAt: string
  finishedAt?: string
  summary?: string
  /** 1 for a fresh task, plus one per reply. */
  turns: number
  approvals: ApprovalMode
  pendingApproval?: PendingApproval
  /** Absolute guest paths of the files attached at start. */
  attachments?: string[]
  /** Set when the task failed because the agent is signed out: the ways to sign in. */
  signIn?: SignInMethod[]
}

export type AgentEvent =
  | { type: 'agent.task.started'; id: string; agent: string; agentName?: string; prompt: string }
  | { type: 'agent.task.output'; id: string; kind: 'text' | 'tool' | 'error'; text: string }
  | { type: 'agent.task.paused'; id: string }
  | { type: 'agent.task.resumed'; id: string }
  | { type: 'agent.task.finished'; id: string; status: TaskStatus; summary: string; signIn?: SignInMethod[] }
  | { type: 'agent.task.approval'; id: string; request: PendingApproval }
  | { type: 'agent.task.approval.resolved'; id: string; requestId: string; allow: boolean }
  | { type: 'agent.task.replied'; id: string; prompt: string; turn: number }

export interface AgentGuest {
  /** Runs a command in the guest as root; resolves stdout, rejects on non-zero exit. */
  run(command: string, args: string[], timeoutMs?: number): Promise<string>
  /**
   * What a GUI started on the owner's display needs, as `KEY=value` pairs: `DISPLAY=:100`
   * under Xpra, caboose-display's launch environment under Caboose Display. A guest that
   * does not say is Xpra's (see ownerEnv in display.ts).
   */
  ownerEnv?: string[]
}

/** Which agent a task runs, and how. Implemented by AgentCatalog over the ACP registry. */
export interface AgentResolver {
  /** The launch spec for a registry id; throws AgentNotFoundError or AgentInputError. */
  launch(id: string): Promise<AgentLaunch>
  /** The owner's default agent, or null when none is chosen. */
  defaultAgent(): string | null
}

export interface AgentTaskOptions {
  resolver: AgentResolver
  craftServers?: () => Promise<Array<{ name: string; command: string; args: string[]; env: Array<{ name: string; value: string }> }>>
  pollMs?: number
  /** Starts the agent seat's display; defaults to the microVM's systemd unit. */
  ensureSeat?: () => Promise<void>
  /** How long a runner keeps an agent and its session after a turn, waiting for a reply. */
  idleMs?: number
  /** Gives root-owned leftovers in the home back to caboose before a runner starts. */
  home?: HomeOwnership
}

const HOME = '/home/caboose'
const RUNUSER = '/usr/sbin/runuser'
export const AGENTD = '/opt/caboose/agentd/caboose-agentd.mjs'
/** What the guest scripts print when the computer's image has no runner. */
export const RUNNER_MISSING = 'caboose-agentd is not installed in this computer'
const TASK_ID = /^[0-9a-f-]{36}$/
/** The summary of a task that ran before caboose-agentd (no task.json). */
export const LEGACY_SUMMARY = 'Ran before Caboose\'s agent runner, so it cannot be continued. Its transcript is in'
const AGENT_ID = /^[a-z0-9][a-z0-9._-]{0,63}$/
/** Approval request ids are UUIDs minted by caboose-agentd. */
const REQUEST_ID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/
const MAX_PROMPT = 32_000
const MAX_ATTACHMENTS = 4
const MAX_ATTACHMENT_BYTES = 10 * 1024 * 1024
/** Transcript bytes read per poll tick across all live tasks, shared between them. */
const POLL_BUDGET = 1024 * 1024
const MIN_TASK_CHUNK = 64 * 1024
const DEFAULT_IDLE_MS = 10 * 60_000
/** Clients that predate the registry name the two agents they knew. */
const LEGACY_AGENTS: Readonly<Record<string, string>> = { claude: 'claude-acp', codex: 'codex-acp' }

const LAUNCH = [
  'export HOME=/home/caboose DISPLAY=:101 XDG_RUNTIME_DIR=/run/user/1000 DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/agent-bus PATH=/home/caboose/.local/bin:/usr/local/bin:/usr/bin:/bin CABOOSE_TASK_DIR="$PWD"',
  `[ -f ${AGENTD} ] || { echo "${RUNNER_MISSING}" >&2; exit 1; }`,
  'rm -f exit-code',
  `setsid sh -c 'node ${AGENTD} run "$PWD" >> stderr.log 2>&1; echo $? > exit-code' > /dev/null 2>&1 < /dev/null &`,
  'echo $! > pid',
]

/**
 * Sets up a new task in "$1" and starts its runner, detached, as `caboose`: $2 the prompt as
 * written, $3 the agent id, $4 its name, $5 the approval mode, $6 task.json, $7 the first
 * prompt message. Attachments are written before this runs.
 */
export const START_SCRIPT = [
  'set -e',
  'mkdir -p "$1/inbox" "$1/approvals"',
  'cd "$1"',
  'printf %s "$2" > prompt.txt && printf %s "$3" > agent && printf %s "$4" > agent-name && printf %s "$5" > approval-mode && printf 1 > turns',
  'printf %s "$6" > task.json',
  'printf %s "$7" > inbox/.000001.tmp && mv inbox/.000001.tmp inbox/000001.prompt.json',
  ...LAUNCH,
].join('\n')

/**
 * A reply: $2 the prompt message, $3 the turn number, $4 its six-digit inbox name. A runner
 * still waiting after the last turn takes the prompt from its inbox; otherwise (it exited, or
 * did not take it within 20 s and is stopped) a new runner starts and takes it.
 */
export const REPLY_SCRIPT = [
  'set -e',
  'cd "$1"',
  'printf %s "$3" > turns',
  'mkdir -p inbox',
  'printf %s "$2" > "inbox/.$4.tmp" && mv "inbox/.$4.tmp" "inbox/$4.prompt.json"',
  'pid=$(cat pid 2>/dev/null || true)',
  'if [ -n "$pid" ] && [ ! -e exit-code ] && kill -0 "$pid" 2>/dev/null; then',
  '  for i in $(seq 1 100); do',
  '    [ -e "inbox/$4.prompt.json" ] || { echo delivered; exit 0; }',
  '    kill -0 "$pid" 2>/dev/null || break',
  '    sleep 0.2',
  '  done',
  '  if kill -0 "$pid" 2>/dev/null; then kill -TERM -- -"$pid" 2>/dev/null || kill -TERM "$pid" 2>/dev/null || true; sleep 1; fi',
  'fi',
  '[ -e "inbox/$4.prompt.json" ] || { echo delivered; exit 0; }',
  ...LAUNCH,
  'echo launched',
].join('\n')

/** Asks the runner in "$1" to cancel its turn, and continues it first if it was paused. */
const CANCEL_SCRIPT = [
  'cd "$1" 2>/dev/null || exit 0',
  'mkdir -p inbox',
  'n=$(date +%s%N)',
  `printf '{"type":"cancel"}' > "inbox/.cancel-$n.tmp" && mv "inbox/.cancel-$n.tmp" "inbox/cancel-$n.json"`,
  'pid=$(cat pid 2>/dev/null) && { kill -CONT -- -"$pid" 2>/dev/null || kill -CONT "$pid" 2>/dev/null; } || true',
].join('\n')

type Output = { kind: 'text' | 'tool' | 'error'; text: string }
export interface TurnResult { turn: number; status: 'succeeded' | 'failed' | 'cancelled'; summary: string; signIn?: SignInMethod[] }

/**
 * Turns one line of the runner's transcript into display events, the start of a turn, or a
 * turn's result. The transcript is the same for every agent (guest/agentd/README.md).
 */
export function interpretLine(line: string): { outputs: Output[]; turn?: number; result?: TurnResult } {
  let event: any
  try { event = JSON.parse(line) } catch { return { outputs: [] } }
  const turn = Number.isSafeInteger(event?.turn) ? event.turn as number : undefined
  switch (event?.type) {
    case 'user':
      return turn === undefined ? { outputs: [] } : { outputs: [], turn }
    case 'text':
      return { outputs: typeof event.text === 'string' && event.text ? [{ kind: 'text', text: event.text }] : [] }
    case 'tool': {
      const title = typeof event.title === 'string' && event.title ? event.title : 'Tool'
      const detail = typeof event.detail === 'string' && event.detail && !title.includes(event.detail) ? `: ${event.detail}` : ''
      return { outputs: [{ kind: 'tool', text: `${title}${detail}` }] }
    }
    case 'turn_end': {
      if (turn === undefined) return { outputs: [] }
      const stop = event.stopReason
      const status = stop === 'end_turn' ? 'succeeded' : stop === 'cancelled' ? 'cancelled' : 'failed'
      return { outputs: [], result: { turn, status, summary: typeof event.summary === 'string' && event.summary ? event.summary : 'Done.' } }
    }
    case 'turn_failed': {
      if (turn === undefined) return { outputs: [] }
      const message = typeof event.message === 'string' && event.message ? event.message : 'The agent failed.'
      return { outputs: [{ kind: 'error', text: message }], result: { turn, status: 'failed', summary: message } }
    }
    case 'auth_required': {
      if (turn === undefined) return { outputs: [] }
      const signIn = readSignIn(event.authMethods)
      return { outputs: [], result: { turn, status: 'failed', summary: '', signIn } }
    }
    default:
      return { outputs: [] }
  }
}

function readSignIn(value: unknown): SignInMethod[] {
  if (!Array.isArray(value)) return []
  return value.flatMap(item => {
    if (!item || typeof item.id !== 'string' || typeof item.name !== 'string' || (item.type !== 'agent' && item.type !== 'terminal')) return []
    return [{ id: item.id.slice(0, 200), name: item.name.slice(0, 200), ...(typeof item.description === 'string' && item.description ? { description: item.description.slice(0, 500) } : {}), type: item.type }]
  })
}

/** One line for the owner about what an approval request would do, when the runner gave none. */
export function describeRequest(tool: string, input: unknown): string {
  const fields = input && typeof input === 'object' ? input as Record<string, unknown> : {}
  const pick = (key: string) => typeof fields[key] === 'string' ? (fields[key] as string) : undefined
  const detail = pick('command') ?? pick('file_path') ?? pick('url') ?? pick('path') ?? pick('pattern') ?? pick('query')
    ?? (Object.keys(fields).length ? JSON.stringify(fields) : '')
  const text = detail && !tool.includes(detail) ? `${tool}: ${detail}` : tool
  return text.length > 300 ? `${text.slice(0, 299)}…` : text
}

/** Reads one approvals/<id>.json written by caboose-agentd. */
export function parseRequest(id: string, json: string): { request: PendingApproval; requestedAt: string } | undefined {
  if (!REQUEST_ID.test(id)) return undefined
  let value: any
  try { value = JSON.parse(json) } catch { return undefined }
  const tool = typeof value?.tool === 'string' && value.tool ? value.tool.slice(0, 200) : undefined
  if (!tool) return undefined
  const summary = typeof value.summary === 'string' && value.summary ? value.summary.slice(0, 300) : describeRequest(tool, value.input)
  const options = Array.isArray(value.options)
    ? value.options.filter((option: any) => typeof option?.id === 'string' && typeof option.name === 'string' && typeof option.kind === 'string')
      .slice(0, 10).map((option: any) => ({ id: option.id.slice(0, 200), name: option.name.slice(0, 200), kind: option.kind.slice(0, 40) }))
    : []
  return { request: { id, tool, summary, ...(options.length ? { options } : {}) }, requestedAt: typeof value.requestedAt === 'string' ? value.requestedAt : '' }
}

interface Tracked {
  task: AgentTask
  offset: number
  carry: Buffer
  /** The turn the transcript is in, by its latest `user` line; output of older turns is not shown. */
  turn: number
  /** Started by the runner (task.json exists), so a reply can continue it. */
  resumable: boolean
  /** Approval requests the agent is waiting on, oldest first. */
  pending: Array<PendingApproval & { requestedAt: string }>
  replying?: boolean
}

export class AgentTasks {
  private readonly tracked = new Map<string, Tracked>()
  private readonly releases = new Map<string, () => void>()
  private timer: ReturnType<typeof setInterval> | undefined
  private polling = false
  private readonly resolver: AgentResolver
  private readonly craftServers?: AgentTaskOptions["craftServers"]
  private readonly pollMs: number
  private readonly ensureSeat?: () => Promise<void>
  private readonly idleMs: number
  private readonly home?: HomeOwnership

  constructor(
    private readonly guest: () => AgentGuest | undefined,
    private readonly emit: (event: AgentEvent) => void,
    private readonly acquire: () => () => void,
    options: AgentTaskOptions,
  ) {
    this.resolver = options.resolver
    this.craftServers = options.craftServers
    this.pollMs = options.pollMs ?? 1000
    this.ensureSeat = options.ensureSeat
    this.idleMs = options.idleMs ?? DEFAULT_IDLE_MS
    this.home = options.home
  }

  list(): AgentTask[] {
    return [...this.tracked.values()].map(entry => entry.task).sort((a, b) => b.startedAt.localeCompare(a.startedAt))
  }

  /** A cold restart cannot leave leases held by processes that no longer exist. */
  computerRestarted(): void {
    this.home?.reset()
    this.pause()
    for (const entry of this.tracked.values()) {
      if (isLive(entry.task.status)) this.finish(entry, 'failed', 'Stopped when the computer restarted.')
    }
  }

  async start(input: Record<string, unknown>): Promise<AgentTask> {
    const prompt = readPrompt(input.prompt)
    const agentId = this.readAgent(input.agent)
    const approvals = input.approvals === 'ask' ? 'ask' : input.approvals === 'auto' || input.approvals === undefined ? 'auto' : undefined
    if (!approvals) throw new AgentInputError('approvals must be "ask" or "auto"')
    if (input.craftMcp !== undefined && typeof input.craftMcp !== 'boolean') throw new AgentInputError('craftMcp must be a boolean')
    const files = readAttachments(input.attachments)
    const guest = this.guest()
    if (!guest) throw new AgentUnavailableError()
    const launch = await this.resolver.launch(agentId)
    const id = randomUUID()
    const dir = `${HOME}/Agents/${id}`
    const attachments = files.map(file => `${dir}/attachments/${file.name}`)
    await this.prepareSeat(guest)
    try {
      for (const [index, file] of files.entries()) {
        const path = attachments[index]!
        await writeGuestFile(guest, `${path}.part`, file.data)
        await asCaboose(guest, 'mv -- "$1.part" "$1"', [path])
      }
      const craftServers = input.craftMcp === false ? [] : await this.craftServers?.() ?? []
      const config = JSON.stringify({ agent: launch, cwd: dir, approvals, idleMs: this.idleMs, craftServers })
      const message = JSON.stringify({ type: 'prompt', turn: 1, text: prompt,
        ...(files.length ? { attachments: files.map((file, index) => ({ path: attachments[index], name: file.name, ...(file.type ? { mimeType: file.type } : {}) })) } : {}) })
      await asCaboose(guest, START_SCRIPT, [dir, prompt, agentId, launch.name, approvals, config, message]).catch(rethrowRunnerMissing)
    } catch (error) {
      await asCaboose(guest, 'rm -rf -- "$1"', [dir]).catch(() => {})
      throw error
    }
    const task: AgentTask = {
      id, agent: agentId, agentName: launch.name, prompt, status: 'running', startedAt: new Date().toISOString(), turns: 1, approvals,
      ...(attachments.length ? { attachments } : {}),
    }
    this.tracked.set(id, { task, offset: 0, carry: Buffer.alloc(0), turn: 0, resumable: true, pending: [] })
    this.releases.set(id, this.acquire())
    this.emit({ type: 'agent.task.started', id, agent: agentId, agentName: launch.name, prompt })
    this.ensurePolling()
    return task
  }

  private readAgent(value: unknown): string {
    if (value === undefined || value === null || value === '') {
      const fallback = this.resolver.defaultAgent()
      if (!fallback) throw new AgentInputError('Choose an agent: pass agent, or set a default agent in Settings')
      return fallback
    }
    if (typeof value !== 'string') throw new AgentInputError('agent must be an agent id from the registry')
    const id = LEGACY_AGENTS[value] ?? value
    if (!AGENT_ID.test(id)) throw new AgentInputError('agent must be an agent id from the registry')
    return id
  }

  /**
   * Continues a finished task's conversation with a new prompt. A runner still waiting keeps
   * the same session; a new runner reopens it (session/resume or session/load) or, for an
   * agent that can do neither, starts a new one with a recap. The turn appends to the same
   * transcript.
   */
  async reply(id: string, input: Record<string, unknown>): Promise<AgentTask> {
    const entry = TASK_ID.test(id) ? this.tracked.get(id) : undefined
    if (!entry) throw new AgentNotFoundError()
    const prompt = readPrompt(input.prompt)
    if (isLive(entry.task.status) || entry.replying) throw new AgentConflictError('The task is still working; wait for it to finish or cancel it first.')
    if (!entry.resumable) throw new AgentConflictError('This task was started by an earlier version of Caboose and cannot be continued.')
    const guest = this.guest()
    if (!guest) throw new AgentUnavailableError()
    const turn = entry.task.turns + 1
    entry.replying = true
    try {
      await this.prepareSeat(guest)
      const name = String(turn).padStart(6, '0')
      await asCaboose(guest, REPLY_SCRIPT, [`${HOME}/Agents/${id}`, JSON.stringify({ type: 'prompt', turn, text: prompt }), String(turn), name], 40_000)
        .catch(rethrowRunnerMissing)
    } finally {
      entry.replying = false
    }
    // Lines still to come from the earlier turn are read but not shown.
    entry.pending = []
    const task = entry.task
    task.status = 'running'
    task.turns = turn
    delete task.finishedAt
    delete task.summary
    delete task.pendingApproval
    delete task.signIn
    this.releases.get(id)?.()
    this.releases.set(id, this.acquire())
    this.emit({ type: 'agent.task.replied', id, prompt, turn })
    this.ensurePolling()
    return task
  }

  /** Answers the approval request `requestId` of task `id`; false when it is not waiting. */
  async resolveApproval(id: string, requestId: string, input: Record<string, unknown>): Promise<boolean> {
    const entry = TASK_ID.test(id) ? this.tracked.get(id) : undefined
    if (!entry) throw new AgentNotFoundError()
    if (!REQUEST_ID.test(requestId)) throw new AgentInputError('unknown approval request')
    if (typeof input.allow !== 'boolean') throw new AgentInputError('allow must be a boolean')
    if (input.message !== undefined && (typeof input.message !== 'string' || input.message.length > 2000)) {
      throw new AgentInputError('message must be a string of at most 2000 characters')
    }
    if (input.optionId !== undefined && (typeof input.optionId !== 'string' || !input.optionId || input.optionId.length > 200)) {
      throw new AgentInputError('optionId must be one of the request\'s option ids')
    }
    if (!isLive(entry.task.status)) return false
    const guest = this.guest()
    if (!guest) throw new AgentUnavailableError()
    const decision = JSON.stringify({
      allow: input.allow,
      ...(typeof input.message === 'string' && input.message.trim() ? { message: input.message.trim() } : {}),
      ...(typeof input.optionId === 'string' ? { optionId: input.optionId } : {}),
    })
    const out = await asCaboose(guest, [
      'cd "$1/approvals" 2>/dev/null || exit 0',
      '[ -f "$2.json" ] && [ ! -e "$2.decision" ] || exit 0',
      'printf %s "$3" > "$2.decision.tmp" && mv -- "$2.decision.tmp" "$2.decision" && printf resolved',
    ].join('\n'), [`${HOME}/Agents/${id}`, requestId, decision])
    entry.pending = entry.pending.filter(request => request.id !== requestId)
    this.syncPending(entry)
    if (out.trim() !== 'resolved') return false
    this.emit({ type: 'agent.task.approval.resolved', id, requestId, allow: input.allow })
    return true
  }

  /** Cancels the running turn: the runner sends ACP session/cancel and answers waiting requests "cancelled". */
  async cancel(id: string): Promise<boolean> {
    const entry = this.tracked.get(id)
    const guest = this.guest()
    if (!entry || !TASK_ID.test(id) || !isLive(entry.task.status) || !guest) return false
    await asCaboose(guest, CANCEL_SCRIPT, [`${HOME}/Agents/${id}`])
    this.finish(entry, 'cancelled', 'Cancelled.')
    return true
  }

  /**
   * Taking over an agent's window stops the agent (SIGSTOP to its whole process group) so the
   * owner and the agent never type into the same app at once; handing back continues it.
   */
  async pauseTask(id: string): Promise<boolean> { return this.hold(id, true) }
  async resumeTask(id: string): Promise<boolean> { return this.hold(id, false) }

  private async hold(id: string, paused: boolean): Promise<boolean> {
    const entry = this.tracked.get(id)
    const guest = this.guest()
    if (!entry || !TASK_ID.test(id) || !guest || entry.task.status !== (paused ? 'running' : 'paused')) return false
    await guest.run('/bin/sh', ['-c', signal(paused ? 'STOP' : 'CONT'), 'sh', `${HOME}/Agents/${id}`], 15_000)
    entry.task.status = paused ? 'paused' : 'running'
    this.emit({ type: paused ? 'agent.task.paused' : 'agent.task.resumed', id })
    return true
  }

  private async prepareSeat(guest: AgentGuest): Promise<void> {
    await this.home?.ensure(guest)
    if (this.ensureSeat) await this.ensureSeat().catch(error => console.error('Agent seat did not start:', error))
    else await guest.run('/bin/sh', ['-c', 'systemctl start caboose-xpra-agent.service || true'], 30_000)
  }

  /**
   * Rebuilds the task list from the task directories in the guest, once per host process,
   * so a host restart neither forgets tasks nor drops the lease under one still running.
   */
  async restore(): Promise<void> {
    const guest = this.guest()
    if (this.restored || !guest) return
    this.restored = true
    const listing = await guest.run('/bin/sh', ['-c', RESTORE_SCRIPT, 'sh', `${HOME}/Agents`], 20_000).catch(() => '')
    for (const line of listing.split('\n')) {
      const [id, agent, started, exitCode, alive, size, prompt, last, mode, turnsField, resumable, attached, name] = line.split('\t')
      if (!id || !TASK_ID.test(id) || this.tracked.has(id)) continue
      const attachments = decode(attached).split('\n').filter(file => file && !file.endsWith('.part')).map(file => `${HOME}/Agents/${id}/attachments/${file}`)
      const turns = Math.max(1, Number.parseInt(turnsField ?? '', 10) || 1)
      const agentId = agent && AGENT_ID.test(agent) ? LEGACY_AGENTS[agent] ?? agent : 'unknown'
      const agentName = decode(name).trim().slice(0, 100)
      const task: AgentTask = {
        id, agent: agentId, ...(agentName ? { agentName } : {}), prompt: decode(prompt), status: 'running',
        startedAt: new Date(Number(started) * 1000).toISOString(),
        turns, approvals: mode === 'ask' ? 'ask' : 'auto',
        ...(attachments.length ? { attachments } : {}),
      }
      const entry: Tracked = { task, offset: Number(size) || 0, carry: Buffer.alloc(0), turn: turns, resumable: resumable === '1', pending: [] }
      this.tracked.set(id, entry)
      const result = interpretLine(decode(last)).result
      if (result && result.turn === turns) {
        this.finishWith(entry, result, false)
      } else if (exitCode === '' && alive === '1') {
        this.releases.set(id, this.acquire())
      } else if (exitCode === '') {
        this.finish(entry, 'failed', 'Stopped when the computer restarted.', false)
      } else if (!entry.resumable) {
        // Ran before caboose-agentd, by an agent's own CLI: its transcript is in that CLI's
        // format, which the host no longer reads, so point the owner at it instead.
        this.finish(entry, exitCode === '0' ? 'succeeded' : 'failed', `${LEGACY_SUMMARY} ${HOME}/Agents/${id}/transcript.jsonl.`, false)
      } else {
        this.finish(entry, 'failed', `The agent runner exited with code ${exitCode} before the turn ended.`, false)
      }
    }
    this.resume()
  }

  private restored = false

  /** Stops tailing (the computer is parking); running tasks resume being tailed on wake. */
  pause(): void {
    if (this.timer) clearInterval(this.timer)
    this.timer = undefined
  }

  resume(): void {
    if (!this.restored) void this.restore()
    if ([...this.tracked.values()].some(entry => isLive(entry.task.status))) this.ensurePolling()
  }

  private ensurePolling(): void {
    if (this.timer) return
    this.timer = setInterval(() => { void this.poll() }, this.pollMs)
    this.timer.unref()
  }

  /**
   * One guest command per tick reads every live task: new transcript bytes, the runner's exit
   * code, and pending approval requests. A tick with no live task does nothing.
   */
  async poll(): Promise<void> {
    const live = [...this.tracked.values()].filter(entry => isLive(entry.task.status))
    if (!live.length) { this.pause(); return }
    const guest = this.guest()
    if (this.polling || !guest) return
    this.polling = true
    try {
      const chunk = Math.max(MIN_TASK_CHUNK, Math.floor(POLL_BUDGET / live.length))
      const output = await guest.run('/bin/sh', ['-c', POLL_SCRIPT, 'sh', String(chunk),
        ...live.flatMap(entry => [`${HOME}/Agents/${entry.task.id}`, String(entry.offset)])], 20_000).catch(() => undefined)
      if (output === undefined) return
      const reports = parsePoll(output)
      for (const entry of live) {
        const report = reports.get(entry.task.id)
        if (report && isLive(entry.task.status)) this.apply(entry, report, chunk)
      }
    } finally {
      this.polling = false
      if (![...this.tracked.values()].some(entry => isLive(entry.task.status))) this.pause()
    }
  }

  private apply(entry: Tracked, report: PollReport, chunk: number): void {
    const id = entry.task.id
    entry.offset += report.data.length
    const buffer = entry.carry.length ? Buffer.concat([entry.carry, report.data]) : report.data
    let start = 0
    let result: TurnResult | undefined
    for (let end = buffer.indexOf(10); end >= 0; start = end + 1, end = buffer.indexOf(10, start)) {
      const line = buffer.subarray(start, end).toString('utf8')
      if (!line.trim()) continue
      const interpreted = interpretLine(line)
      if (interpreted.turn !== undefined) entry.turn = interpreted.turn
      if (entry.turn === entry.task.turns) {
        for (const output of interpreted.outputs) this.emit({ type: 'agent.task.output', id, ...output })
      }
      if (interpreted.result?.turn === entry.task.turns) result ??= interpreted.result
    }
    entry.carry = Buffer.from(buffer.subarray(start))
    if (result) return this.finishWith(entry, result)
    this.updatePending(entry, report.requests)
    // A full chunk means more transcript is waiting; finish only once it has all been read.
    if (report.exitCode === '' || report.data.length >= chunk) return
    const stderr = report.stderr.trim()
    this.finish(entry, 'failed', stderr || `The agent runner exited with code ${report.exitCode} before the turn ended.`)
  }

  private finishWith(entry: Tracked, result: TurnResult, announce = true): void {
    if (result.signIn) {
      const name = entry.task.agentName ?? entry.task.agent
      return this.finish(entry, 'failed', `Sign in to ${name} first.`, announce, result.signIn)
    }
    this.finish(entry, result.status, result.summary, announce)
  }

  /** Announces new approval requests and forgets ones answered elsewhere. */
  private updatePending(entry: Tracked, requests: Array<{ id: string; json: string }>): void {
    const known = new Set(entry.pending.map(request => request.id))
    const reported = new Set<string>()
    for (const { id, json } of requests) {
      reported.add(id)
      if (known.has(id)) continue
      const parsed = parseRequest(id, json)
      if (!parsed) continue
      entry.pending.push({ ...parsed.request, requestedAt: parsed.requestedAt })
      this.emit({ type: 'agent.task.approval', id: entry.task.id, request: parsed.request })
    }
    entry.pending = entry.pending.filter(request => reported.has(request.id)).sort((a, b) => a.requestedAt.localeCompare(b.requestedAt))
    this.syncPending(entry)
  }

  private syncPending(entry: Tracked): void {
    const first = entry.pending[0]
    if (first) entry.task.pendingApproval = { id: first.id, tool: first.tool, summary: first.summary, ...(first.options ? { options: first.options } : {}) }
    else delete entry.task.pendingApproval
  }

  private finish(entry: Tracked, status: TaskStatus, summary: string, announce = true, signIn?: SignInMethod[]): void {
    if (!isLive(entry.task.status)) return
    entry.task.status = status
    entry.task.finishedAt = new Date().toISOString()
    entry.task.summary = summary.slice(0, 2000)
    if (signIn) entry.task.signIn = signIn
    entry.pending = []
    delete entry.task.pendingApproval
    this.releases.get(entry.task.id)?.()
    this.releases.delete(entry.task.id)
    if (announce) this.emit({ type: 'agent.task.finished', id: entry.task.id, status, summary: entry.task.summary, ...(signIn ? { signIn } : {}) })
  }
}

function isLive(status: TaskStatus): boolean { return status === 'running' || status === 'paused' }

function readPrompt(value: unknown): string {
  const prompt = typeof value === 'string' ? value.trim() : ''
  if (!prompt || prompt.length > MAX_PROMPT) throw new AgentInputError('prompt must be 1–32000 characters')
  return prompt
}

/** Validates `attachments` on task start: ≤ 4 files, ≤ 10 MB decoded together, names made safe and unique. */
export function readAttachments(value: unknown): Array<{ name: string; type: string; data: Buffer }> {
  if (value === undefined) return []
  if (!Array.isArray(value) || value.length > MAX_ATTACHMENTS) throw new AgentInputError('attachments must be a list of at most 4 files')
  const taken = new Set<string>()
  let total = 0
  return value.map((item, index) => {
    if (!item || typeof item !== 'object') throw new AgentInputError(`attachments[${index}] must be { name, type, data }`)
    const { name, type, data } = item as Record<string, unknown>
    if (typeof name !== 'string' || !name.trim()) throw new AgentInputError(`attachments[${index}].name is required`)
    if (type !== undefined && (typeof type !== 'string' || type.length > 255)) throw new AgentInputError(`attachments[${index}].type must be a MIME type`)
    const bytes = decodeBase64(data, `attachments[${index}].data`)
    if (!bytes.length) throw new AgentInputError(`attachments[${index}] is empty`)
    total += bytes.length
    if (total > MAX_ATTACHMENT_BYTES) throw new AgentInputError('attachments are limited to 10 MB together')
    const unique = uniqueName(sanitizeFileName(name), taken)
    taken.add(unique)
    return { name: unique, type: typeof type === 'string' ? type : '', data: bytes }
  })
}

/** A computer made from an image older than the runner says so, with what to do about it (409). */
export function rethrowRunnerMissing(error: unknown): never {
  if (error instanceof Error && error.message.includes(RUNNER_MISSING)) {
    throw new AgentConflictError('This computer has no agent runner. Rebuild its image, or run guest/agentd/install.sh in it as root.')
  }
  throw error
}

function asCaboose(guest: AgentGuest, script: string, args: string[], timeoutMs = 15_000): Promise<string> {
  return guest.run(RUNUSER, ['-u', 'caboose', '--', '/bin/sh', '-c', script, 'sh', ...args], timeoutMs)
}

/** Signals a task's process group (falling back to its pid); $1 is the task directory. */
function signal(name: 'TERM' | 'STOP' | 'CONT'): string {
  return `pid=$(cat "$1/pid" 2>/dev/null) && { kill -${name} -- -"$pid" 2>/dev/null || kill -${name} "$pid" 2>/dev/null; } || true`
}

function decode(value: string | undefined): string {
  return value ? Buffer.from(value, 'base64').toString('utf8') : ''
}

interface PollReport { exitCode: string; stderr: string; data: Buffer; requests: Array<{ id: string; json: string }> }

/**
 * The batched poll: $1 is the per-task byte budget, then pairs of task directory and
 * transcript offset. Per task, one line `T <id> <exit code> <stderr b64> <new bytes b64>`
 * and one `A <id> <request id> <request b64>` per approval request without a decision.
 */
const POLL_SCRIPT = [
  'max=$1; shift',
  'while [ $# -ge 2 ]; do',
  '  d=$1; o=$2; shift 2; id=${d##*/}',
  '  e=$(cat "$d/exit-code" 2>/dev/null || true); err=""',
  '  [ -n "$e" ] && err=$(tail -c 400 "$d/stderr.log" 2>/dev/null | base64 -w0)',
  "  printf 'T\\t%s\\t%s\\t%s\\t' \"$id\" \"$e\" \"$err\"",
  '  tail -c +"$((o + 1))" "$d/transcript.jsonl" 2>/dev/null | head -c "$max" | base64 -w0',
  "  printf '\\n'",
  '  for f in "$d"/approvals/*.json; do',
  '    [ -f "$f" ] || continue',
  '    r=${f##*/}; r=${r%.json}',
  '    [ -e "$d/approvals/$r.decision" ] && continue',
  "    printf 'A\\t%s\\t%s\\t%s\\n' \"$id\" \"$r\" \"$(head -c 65536 \"$f\" | base64 -w0)\"",
  '  done',
  'done',
].join('\n')

export function parsePoll(output: string): Map<string, PollReport> {
  const reports = new Map<string, PollReport>()
  for (const line of output.split('\n')) {
    const fields = line.split('\t')
    if (fields[0] === 'T' && fields[1] && TASK_ID.test(fields[1])) {
      reports.set(fields[1], { exitCode: (fields[2] ?? '').trim(), stderr: decode(fields[3]).replace(/\n/g, ' '), data: Buffer.from(fields[4] ?? '', 'base64'), requests: [] })
    } else if (fields[0] === 'A' && fields[1] && fields[2] && REQUEST_ID.test(fields[2])) {
      reports.get(fields[1])?.requests.push({ id: fields[2], json: decode(fields[3]) })
    }
  }
  return reports
}

/**
 * One tab-separated line per task directory, newest 30: id, agent id, start time, the
 * runner's exit code, whether it is alive, transcript size, base64 prompt, base64 last line
 * that ends a turn, approval mode, turns, whether task.json exists (1 or 0), base64
 * attachment names, base64 agent name.
 */
const RESTORE_SCRIPT = [
  'cd "$1" 2>/dev/null || exit 0',
  'for d in $(ls -1t | head -30); do',
  '  [ -f "$d/prompt.txt" ] || continue',
  '  pid=$(cat "$d/pid" 2>/dev/null); alive=0; [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null && alive=1',
  '  resumable=0; [ -f "$d/task.json" ] && resumable=1',
  `  last=$(grep -E '"type":"(turn_end|turn_failed|auth_required)"' "$d/transcript.jsonl" 2>/dev/null | tail -n 1)`,
  '  printf "%s\\t%s\\t%s\\t%s\\t%s\\t%s\\t%s\\t%s\\t%s\\t%s\\t%s\\t%s\\t%s\\n" "$d" "$(cat "$d/agent" 2>/dev/null)" "$(stat -c %Y "$d/prompt.txt")" \\',
  '    "$(cat "$d/exit-code" 2>/dev/null)" "$alive" "$(stat -c %s "$d/transcript.jsonl" 2>/dev/null || echo 0)" \\',
  '    "$(base64 -w0 < "$d/prompt.txt")" "$(printf %s "$last" | base64 -w0)" \\',
  '    "$(cat "$d/approval-mode" 2>/dev/null || echo auto)" "$(cat "$d/turns" 2>/dev/null || echo 1)" "$resumable" \\',
  '    "$(ls -1 "$d/attachments" 2>/dev/null | base64 -w0)" "$(cat "$d/agent-name" 2>/dev/null | base64 -w0)"',
  'done',
].join('\n')

export class AgentInputError extends Error {}
export class AgentUnavailableError extends Error {
  constructor() { super('computer is not running') }
}
/** The task exists but is not in a state that allows the request (409). */
export class AgentConflictError extends Error {}
/** Something in the computer failed while carrying out an agent operation, such as an install (502). */
export class AgentOperationError extends Error {}
export class AgentNotFoundError extends Error {
  constructor(message = 'task not found') { super(message) }
}
