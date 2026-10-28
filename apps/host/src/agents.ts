import { randomUUID } from 'node:crypto'
import { decodeBase64, sanitizeFileName, uniqueName, writeGuestFile } from './files.js'

/**
 * Agent tasks: Claude Code or Codex run headless inside the owner's computer, as user
 * `caboose`, on the agent seat (DISPLAY=:101). Each task lives in
 * /home/caboose/Agents/<id>/ with its prompt, its raw JSONL transcript (every turn appended),
 * its pid and conversation id, so a task outlives a host restart and the transcript is the
 * record. The host tails the
 * transcript and turns it into control-socket events. See docs/architecture.md § Agents.
 */
export type AgentKind = 'claude' | 'codex'
export type TaskStatus = 'running' | 'paused' | 'succeeded' | 'failed' | 'cancelled'

export type ApprovalMode = 'ask' | 'auto'

/** A tool use the agent is waiting on the owner to allow or deny. */
export interface PendingApproval { id: string; tool: string; summary: string }

export interface AgentTask {
  id: string
  agent: AgentKind
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
}

export type AgentEvent =
  | { type: 'agent.task.started'; id: string; agent: AgentKind; prompt: string }
  | { type: 'agent.task.output'; id: string; kind: 'text' | 'tool' | 'error'; text: string }
  | { type: 'agent.task.paused'; id: string }
  | { type: 'agent.task.resumed'; id: string }
  | { type: 'agent.task.finished'; id: string; status: TaskStatus; summary: string }
  | { type: 'agent.task.approval'; id: string; request: PendingApproval }
  | { type: 'agent.task.approval.resolved'; id: string; requestId: string; allow: boolean }
  | { type: 'agent.task.replied'; id: string; prompt: string; turn: number }

export interface AgentGuest {
  /** Runs a command in the guest as root; resolves stdout, rejects on non-zero exit. */
  run(command: string, args: string[], timeoutMs?: number): Promise<string>
}

const HOME = '/home/caboose'
const RUNUSER = '/usr/sbin/runuser'
const TASK_ID = /^[0-9a-f-]{36}$/
/** Approval request ids are UUIDs minted by caboose-desktop-mcp. */
const REQUEST_ID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/
/** Claude session ids and Codex thread ids are UUIDs; allow a little more, never shell or path syntax. */
const SESSION_ID = /^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$/
const MAX_PROMPT = 32_000
const MAX_ATTACHMENTS = 4
const MAX_ATTACHMENT_BYTES = 10 * 1024 * 1024
/** Transcript bytes read per poll tick across all live tasks, shared between them. */
const POLL_BUDGET = 1024 * 1024
const MIN_TASK_CHUNK = 64 * 1024
const APPROVE_TOOL = 'mcp__caboose-desktop__approve'

/**
 * The shell that starts one turn of a task detached from the desk agent, as `caboose`, in
 * the task directory "$1". The turn's prompt is in turn.txt; a resumed turn continues the
 * conversation recorded in `session`. Every turn appends to the same transcript.jsonl.
 */
export function launchScript(agent: AgentKind, options: { approvals?: ApprovalMode; resume?: boolean } = {}): string {
  const resume = options.resume === true
  const cli = agent === 'claude'
    ? [
        'claude -p "$(cat turn.txt)"',
        ...(resume ? ['--resume "$(cat session)"'] : []),
        '--output-format stream-json --verbose',
        options.approvals === 'ask'
          // Every tool use that needs permission asks the owner through caboose-desktop-mcp.
          ? `--permission-prompt-tool ${APPROVE_TOOL}`
          // Headless Claude denies tools that are not pre-approved, so name the ones an agent on
          // its own seat needs: the shell, files, the web, and the desktop tools for GUI apps.
          : '--permission-mode acceptEdits --allowedTools Bash,Read,Edit,Write,Glob,Grep,WebFetch,WebSearch,mcp__caboose-desktop',
      ].join(' ')
    // `codex exec` cannot ask, so it runs in the workspace-write sandbox. `codex exec resume`
    // takes no --sandbox flag; the config override works for both.
    : `codex exec ${resume ? 'resume ' : ''}--json --skip-git-repo-check -c sandbox_mode=workspace-write ${resume ? '"$(cat session)" ' : ''}"$(cat turn.txt)"`
  return [
    'set -e',
    'cd "$1"',
    'export HOME=/home/caboose DISPLAY=:101 PATH=/usr/local/bin:/usr/bin:/bin CABOOSE_TASK_DIR="$PWD"',
    `setsid sh -c '${cli} >> transcript.jsonl 2> stderr.log; echo $? > exit-code' > /dev/null 2>&1 < /dev/null &`,
    'echo $! > pid',
  ].join('\n')
}

/**
 * Before a reply's turn starts: let the previous turn's process finish writing (stopping it
 * after 10 s), then record the turn. $2 prompt, $3 session id, $4 turn number.
 */
const REPLY_PRELUDE = [
  'set -e',
  'cd "$1"',
  'pid=$(cat pid 2>/dev/null || true)',
  'if [ -n "$pid" ]; then',
  '  for i in $(seq 1 50); do kill -0 "$pid" 2>/dev/null || break; sleep 0.2; done',
  '  kill -TERM -- -"$pid" 2>/dev/null || true',
  'fi',
  'printf %s "$2" > turn.txt',
  'printf %s "$3" > session',
  'printf %s "$4" > turns',
  'rm -f exit-code',
].join('\n')

type Output = { kind: 'text' | 'tool' | 'error'; text: string }

/** Turns one transcript line from either CLI into display events, the conversation id, and, at the end, a result. */
export function interpretLine(line: string): { outputs: Output[]; result?: { ok: boolean; summary: string }; session?: string } {
  let event: any
  try { event = JSON.parse(line) } catch { return { outputs: [] } }
  const outputs: Output[] = []
  // Claude Code stream-json
  if (event?.type === 'system' && event.subtype === 'init' && typeof event.session_id === 'string') {
    return { outputs, ...(SESSION_ID.test(event.session_id) ? { session: event.session_id } : {}) }
  }
  if (event?.type === 'assistant' && Array.isArray(event.message?.content)) {
    for (const part of event.message.content) {
      if (part?.type === 'text' && part.text) outputs.push({ kind: 'text', text: String(part.text) })
      if (part?.type === 'tool_use') outputs.push({ kind: 'tool', text: `${part.name}${describeInput(part.input)}` })
    }
  }
  if (event?.type === 'result') {
    const summary = String(event.result ?? (event.is_error ? 'The agent stopped with an error.' : 'Done.'))
    return { outputs, result: { ok: !event.is_error && event.subtype === 'success', summary } }
  }
  // Codex exec --json
  if (event?.type === 'thread.started' && typeof event.thread_id === 'string') {
    return { outputs, ...(SESSION_ID.test(event.thread_id) ? { session: event.thread_id } : {}) }
  }
  const item = event?.item
  if (event?.type === 'item.completed' && item) {
    if (item.type === 'agent_message' && item.text) outputs.push({ kind: 'text', text: String(item.text) })
    if (item.type === 'command_execution') outputs.push({ kind: 'tool', text: `$ ${item.command ?? ''}`.trim() })
    if (item.type === 'file_change') outputs.push({ kind: 'tool', text: `edited ${(item.changes ?? []).map((c: any) => c.path).join(', ')}` })
    if (item.type === 'error') outputs.push({ kind: 'error', text: String(item.message ?? 'error') })
  }
  if (event?.type === 'turn.failed') return { outputs, result: { ok: false, summary: String(event.error?.message ?? 'The agent failed.') } }
  if (event?.type === 'error') outputs.push({ kind: 'error', text: String(event.message ?? 'error') })
  return { outputs }
}

function describeInput(input: unknown): string {
  if (!input || typeof input !== 'object') return ''
  const value = (input as Record<string, unknown>).command ?? (input as Record<string, unknown>).file_path ?? (input as Record<string, unknown>).url
  return typeof value === 'string' ? `: ${value.slice(0, 160)}` : ''
}

/** One line for the owner about what an approval request would do. */
export function describeRequest(tool: string, input: unknown): string {
  const fields = input && typeof input === 'object' ? input as Record<string, unknown> : {}
  const pick = (key: string) => typeof fields[key] === 'string' ? (fields[key] as string) : undefined
  const detail = pick('command') ?? pick('file_path') ?? pick('url') ?? pick('path') ?? pick('pattern') ?? pick('query')
    ?? (Object.keys(fields).length ? JSON.stringify(fields) : '')
  const name = tool.startsWith('mcp__caboose-desktop__') ? `Desktop ${tool.slice('mcp__caboose-desktop__'.length)}` : tool
  const text = detail ? `${name}: ${detail}` : name
  return text.length > 300 ? `${text.slice(0, 299)}…` : text
}

/** Reads one approvals/<id>.json written by caboose-desktop-mcp. */
export function parseRequest(id: string, json: string): { request: PendingApproval; requestedAt: string } | undefined {
  if (!REQUEST_ID.test(id)) return undefined
  let value: any
  try { value = JSON.parse(json) } catch { return undefined }
  const tool = typeof value?.tool === 'string' && value.tool ? value.tool.slice(0, 200) : undefined
  if (!tool) return undefined
  return { request: { id, tool, summary: describeRequest(tool, value.input) }, requestedAt: typeof value.requestedAt === 'string' ? value.requestedAt : '' }
}

interface Tracked {
  task: AgentTask
  offset: number
  carry: Buffer
  lastText?: string
  /** Claude's session_id or Codex's thread_id, which a reply resumes. */
  session?: string
  /** Approval requests the agent is waiting on, oldest first. */
  pending: Array<PendingApproval & { requestedAt: string }>
  replying?: boolean
}

export class AgentTasks {
  private readonly tracked = new Map<string, Tracked>()
  private readonly releases = new Map<string, () => void>()
  private timer: ReturnType<typeof setInterval> | undefined
  private polling = false

  constructor(
    private readonly guest: () => AgentGuest | undefined,
    private readonly emit: (event: AgentEvent) => void,
    private readonly acquire: () => () => void,
    private readonly pollMs = 1000,
    /** Starts the agent seat's display; defaults to the microVM's systemd unit. */
    private readonly ensureSeat?: () => Promise<void>,
  ) {}

  list(): AgentTask[] {
    return [...this.tracked.values()].map(entry => entry.task).sort((a, b) => b.startedAt.localeCompare(a.startedAt))
  }

  /** A cold restart cannot leave leases held by processes that no longer exist. */
  computerRestarted(): void {
    this.pause()
    for (const entry of this.tracked.values()) {
      if (isLive(entry.task.status)) this.finish(entry, 'failed', 'Stopped when the computer restarted.')
    }
  }

  async start(input: Record<string, unknown>): Promise<AgentTask> {
    const prompt = readPrompt(input.prompt)
    const agent = input.agent === 'codex' ? 'codex' : input.agent === 'claude' || input.agent === undefined ? 'claude' : undefined
    if (!agent) throw new AgentInputError('agent must be "claude" or "codex"')
    const approvals = input.approvals === 'ask' ? 'ask' : input.approvals === 'auto' || input.approvals === undefined ? 'auto' : undefined
    if (!approvals) throw new AgentInputError('approvals must be "ask" or "auto"')
    if (approvals === 'ask' && agent === 'codex') throw new AgentInputError('Codex cannot ask before acting; use approvals "auto"')
    const files = readAttachments(input.attachments)
    const guest = this.guest()
    if (!guest) throw new AgentUnavailableError()
    const id = randomUUID()
    const dir = `${HOME}/Agents/${id}`
    const attachments = files.map(file => `${dir}/attachments/${file.name}`)
    const turnPrompt = attachments.length ? `${prompt}\n\nAttached files:\n${attachments.map(path => `- ${path}`).join('\n')}` : prompt
    await this.prepareSeat(guest)
    await asCaboose(guest, 'mkdir -p "$1" && cd "$1" && printf %s "$2" > prompt.txt && printf %s "$3" > turn.txt && printf %s "$4" > agent && printf %s "$5" > approval-mode && printf 1 > turns',
      [dir, prompt, turnPrompt, agent, approvals])
    try {
      for (const [index, file] of files.entries()) {
        const path = attachments[index]!
        await writeGuestFile(guest, `${path}.part`, file.data)
        await asCaboose(guest, 'mv -- "$1.part" "$1"', [path])
      }
      await asCaboose(guest, launchScript(agent, { approvals }), [dir])
    } catch (error) {
      await asCaboose(guest, 'rm -rf -- "$1"', [dir]).catch(() => {})
      throw error
    }
    const task: AgentTask = { id, agent, prompt, status: 'running', startedAt: new Date().toISOString(), turns: 1, approvals, ...(attachments.length ? { attachments } : {}) }
    this.tracked.set(id, { task, offset: 0, carry: Buffer.alloc(0), pending: [] })
    this.releases.set(id, this.acquire())
    this.emit({ type: 'agent.task.started', id, agent, prompt })
    this.ensurePolling()
    return task
  }

  /**
   * Continues a finished task's conversation with a new prompt: Claude resumes its session,
   * Codex its thread, and the turn appends to the same transcript.
   */
  async reply(id: string, input: Record<string, unknown>): Promise<AgentTask> {
    const entry = TASK_ID.test(id) ? this.tracked.get(id) : undefined
    if (!entry) throw new AgentNotFoundError()
    const prompt = readPrompt(input.prompt)
    if (isLive(entry.task.status) || entry.replying) throw new AgentConflictError('The task is still working; wait for it to finish or cancel it first.')
    if (!entry.session) throw new AgentConflictError('This task has no conversation to continue.')
    const guest = this.guest()
    if (!guest) throw new AgentUnavailableError()
    const turn = entry.task.turns + 1
    entry.replying = true
    try {
      await this.prepareSeat(guest)
      await asCaboose(guest, `${REPLY_PRELUDE}\n${launchScript(entry.task.agent, { approvals: entry.task.approvals, resume: true })}`,
        [`${HOME}/Agents/${id}`, prompt, entry.session, String(turn)], 30_000)
    } finally {
      entry.replying = false
    }
    // A line the last turn left unfinished is dropped; the new turn starts on a line of its own.
    entry.carry = Buffer.alloc(0)
    entry.lastText = undefined
    entry.pending = []
    const task = entry.task
    task.status = 'running'
    task.turns = turn
    delete task.finishedAt
    delete task.summary
    delete task.pendingApproval
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
    if (!isLive(entry.task.status)) return false
    const guest = this.guest()
    if (!guest) throw new AgentUnavailableError()
    const decision = JSON.stringify({ allow: input.allow, ...(typeof input.message === 'string' && input.message.trim() ? { message: input.message.trim() } : {}) })
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

  async cancel(id: string): Promise<boolean> {
    const entry = this.tracked.get(id)
    const guest = this.guest()
    if (!entry || !TASK_ID.test(id) || !isLive(entry.task.status) || !guest) return false
    // A paused task only sees the TERM once it is continued.
    await guest.run('/bin/sh', ['-c', `${signal('TERM')}; ${signal('CONT')}`, 'sh', `${HOME}/Agents/${id}`], 15_000)
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
      const [id, agent, started, exitCode, alive, size, prompt, last, mode, turns, session, attached] = line.split('\t')
      if (!id || !TASK_ID.test(id) || this.tracked.has(id)) continue
      const attachments = decode(attached).split('\n').filter(name => name && !name.endsWith('.part')).map(name => `${HOME}/Agents/${id}/attachments/${name}`)
      const task: AgentTask = {
        id, agent: agent === 'codex' ? 'codex' : 'claude', prompt: decode(prompt), status: 'running',
        startedAt: new Date(Number(started) * 1000).toISOString(),
        turns: Math.max(1, Number.parseInt(turns ?? '', 10) || 1), approvals: mode === 'ask' ? 'ask' : 'auto',
        ...(attachments.length ? { attachments } : {}),
      }
      const entry: Tracked = { task, offset: Number(size) || 0, carry: Buffer.alloc(0), pending: [] }
      const resumable = sessionFrom(decode(session))
      if (resumable) entry.session = resumable
      this.tracked.set(id, entry)
      if (exitCode === '' && alive === '1') {
        this.releases.set(id, this.acquire())
        continue
      }
      const result = interpretLine(decode(last)).result
      if (exitCode === '') this.finish(entry, 'failed', 'Stopped when the computer restarted.', false)
      else this.finish(entry, result ? (result.ok ? 'succeeded' : 'failed') : exitCode === '0' ? 'succeeded' : 'failed',
        result?.summary ?? (exitCode === '0' ? 'Done.' : `The agent exited with code ${exitCode}.`), false)
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
   * One guest command per tick reads every live task: new transcript bytes, the exit code,
   * and pending approval requests. A tick with no live task does nothing.
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
    let result: { ok: boolean; summary: string } | undefined
    for (let end = buffer.indexOf(10); end >= 0; start = end + 1, end = buffer.indexOf(10, start)) {
      const line = buffer.subarray(start, end).toString('utf8')
      if (!line.trim()) continue
      const interpreted = interpretLine(line)
      if (interpreted.session && interpreted.session !== entry.session) {
        entry.session = interpreted.session
        // Kept beside the transcript so a reply still works after a host restart.
        const guest = this.guest()
        if (guest) void asCaboose(guest, 'printf %s "$2" > "$1/session"', [`${HOME}/Agents/${id}`, interpreted.session]).catch(() => {})
      }
      for (const output of interpreted.outputs) {
        if (output.kind === 'text') entry.lastText = output.text
        this.emit({ type: 'agent.task.output', id, ...output })
      }
      result ??= interpreted.result
    }
    entry.carry = Buffer.from(buffer.subarray(start))
    this.updatePending(entry, report.requests)
    if (result) return this.finish(entry, result.ok ? 'succeeded' : 'failed', result.summary)
    // A full chunk means more transcript is waiting; finish only once it has all been read.
    if (report.exitCode === '' || report.data.length >= chunk) return
    const stderr = report.stderr.trim()
    const signedOut = /log ?in|sign ?in|authenticat|api key|unauthori[sz]ed/i.test(stderr)
    const summary = signedOut
      ? `${entry.task.agent === 'claude' ? 'Claude Code' : 'Codex'} is signed out. Open Terminal on your computer and run \`${entry.task.agent}\` once to sign in.`
      : report.exitCode === '0' ? entry.lastText ?? 'Done.' : stderr || `The agent exited with code ${report.exitCode}.`
    this.finish(entry, report.exitCode === '0' && !signedOut ? 'succeeded' : 'failed', summary)
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
    if (first) entry.task.pendingApproval = { id: first.id, tool: first.tool, summary: first.summary }
    else delete entry.task.pendingApproval
  }

  private finish(entry: Tracked, status: TaskStatus, summary: string, announce = true): void {
    if (!isLive(entry.task.status)) return
    entry.task.status = status
    entry.task.finishedAt = new Date().toISOString()
    entry.task.summary = summary.slice(0, 2000)
    entry.pending = []
    delete entry.task.pendingApproval
    this.releases.get(entry.task.id)?.()
    this.releases.delete(entry.task.id)
    if (announce) this.emit({ type: 'agent.task.finished', id: entry.task.id, status, summary: entry.task.summary })
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

/** A session id from the `session` file or, failing that, the transcript's init line. */
function sessionFrom(text: string): string | undefined {
  const trimmed = text.trim()
  if (!trimmed) return undefined
  if (trimmed.startsWith('{')) return interpretLine(trimmed).session
  return SESSION_ID.test(trimmed) ? trimmed : undefined
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
 * One tab-separated line per task directory, newest 30: id, agent, start time, exit code,
 * whether its process is alive, transcript size, base64 prompt, base64 last transcript
 * line, approval mode, turns, base64 session (the `session` file, else the transcript's
 * last init line), and base64 attachment names.
 */
const RESTORE_SCRIPT = [
  'cd "$1" 2>/dev/null || exit 0',
  'for d in $(ls -1t | head -30); do',
  '  [ -f "$d/prompt.txt" ] || continue',
  '  pid=$(cat "$d/pid" 2>/dev/null); alive=0; [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null && alive=1',
  `  s=$(cat "$d/session" 2>/dev/null || grep -E '"subtype":"init"|"type":"thread.started"' "$d/transcript.jsonl" 2>/dev/null | tail -n 1)`,
  '  printf "%s\\t%s\\t%s\\t%s\\t%s\\t%s\\t%s\\t%s\\t%s\\t%s\\t%s\\t%s\\n" "$d" "$(cat "$d/agent" 2>/dev/null || echo claude)" "$(stat -c %Y "$d/prompt.txt")" \\',
  '    "$(cat "$d/exit-code" 2>/dev/null)" "$alive" "$(stat -c %s "$d/transcript.jsonl" 2>/dev/null || echo 0)" \\',
  '    "$(base64 -w0 < "$d/prompt.txt")" "$(tail -n 1 "$d/transcript.jsonl" 2>/dev/null | base64 -w0)" \\',
  '    "$(cat "$d/approval-mode" 2>/dev/null || echo auto)" "$(cat "$d/turns" 2>/dev/null || echo 1)" \\',
  '    "$(printf %s "$s" | base64 -w0)" "$(ls -1 "$d/attachments" 2>/dev/null | base64 -w0)"',
  'done',
].join('\n')

export class AgentInputError extends Error {}
export class AgentUnavailableError extends Error {
  constructor() { super('computer is not running') }
}
/** The task exists but is not in a state that allows the request (409). */
export class AgentConflictError extends Error {}
export class AgentNotFoundError extends Error {
  constructor() { super('task not found') }
}
