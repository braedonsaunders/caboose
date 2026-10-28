import { randomUUID } from 'node:crypto'

/**
 * Agent tasks: Claude Code or Codex run headless inside the owner's computer, as user
 * `caboose`, on the agent seat (DISPLAY=:101). Each task lives in
 * /home/caboose/Agents/<id>/ with its prompt, its raw JSONL transcript and its pid, so a
 * task outlives a host restart and the transcript is the record. The host tails the
 * transcript and turns it into control-socket events. See docs/architecture.md § Agents.
 */
export type AgentKind = 'claude' | 'codex'
export type TaskStatus = 'running' | 'succeeded' | 'failed' | 'cancelled'

export interface AgentTask {
  id: string
  agent: AgentKind
  prompt: string
  status: TaskStatus
  startedAt: string
  finishedAt?: string
  summary?: string
}

export type AgentEvent =
  | { type: 'agent.task.started'; id: string; agent: AgentKind; prompt: string }
  | { type: 'agent.task.output'; id: string; kind: 'text' | 'tool' | 'error'; text: string }
  | { type: 'agent.task.finished'; id: string; status: TaskStatus; summary: string }

export interface AgentGuest {
  /** Runs a command in the guest as root; resolves stdout, rejects on non-zero exit. */
  run(command: string, args: string[], timeoutMs?: number): Promise<string>
}

const HOME = '/home/caboose'
const TASK_ID = /^[0-9a-f-]{36}$/
const MAX_PROMPT = 32_000

/** The shell that starts a task detached from the desk agent, as `caboose`. */
export function launchScript(agent: AgentKind): string {
  const cli = agent === 'claude'
    // Headless Claude denies tools that are not pre-approved, so name the ones an agent on
    // its own seat needs: the shell, files, the web, and the desktop tools for GUI apps.
    ? 'claude -p "$(cat prompt.txt)" --output-format stream-json --verbose --permission-mode acceptEdits --allowedTools Bash,Read,Edit,Write,Glob,Grep,WebFetch,WebSearch,mcp__caboose-desktop'
    : 'codex exec --json --skip-git-repo-check --full-auto "$(cat prompt.txt)"'
  return [
    'set -e',
    'cd "$1"',
    'export HOME=/home/caboose DISPLAY=:101 PATH=/usr/local/bin:/usr/bin:/bin',
    `setsid sh -c '${cli} > transcript.jsonl 2> stderr.log; echo $? > exit-code' > /dev/null 2>&1 < /dev/null &`,
    'echo $! > pid',
  ].join('\n')
}

/** Turns one transcript line from either CLI into display events and, at the end, a result. */
export function interpretLine(line: string): { outputs: Array<{ kind: 'text' | 'tool' | 'error'; text: string }>; result?: { ok: boolean; summary: string } } {
  let event: any
  try { event = JSON.parse(line) } catch { return { outputs: [] } }
  const outputs: Array<{ kind: 'text' | 'tool' | 'error'; text: string }> = []
  // Claude Code stream-json
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

interface Tracked { task: AgentTask; offset: number; carry: string; lastText?: string }

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
  ) {}

  list(): AgentTask[] {
    return [...this.tracked.values()].map(entry => entry.task).sort((a, b) => b.startedAt.localeCompare(a.startedAt))
  }

  async start(input: Record<string, unknown>): Promise<AgentTask> {
    const prompt = typeof input.prompt === 'string' ? input.prompt.trim() : ''
    if (!prompt || prompt.length > MAX_PROMPT) throw new AgentInputError('prompt must be 1–32000 characters')
    const agent = input.agent === 'codex' ? 'codex' : input.agent === 'claude' || input.agent === undefined ? 'claude' : undefined
    if (!agent) throw new AgentInputError('agent must be "claude" or "codex"')
    const guest = this.guest()
    if (!guest) throw new AgentUnavailableError()
    const id = randomUUID()
    const dir = `${HOME}/Agents/${id}`
    await guest.run('/bin/sh', ['-c', 'systemctl start caboose-xpra-agent.service || true'], 30_000)
    await guest.run('/usr/sbin/runuser', ['-u', 'caboose', '--', '/bin/sh', '-c',
      'mkdir -p "$1" && printf %s "$2" > "$1/prompt.txt"', 'sh', dir, prompt], 15_000)
    await guest.run('/usr/sbin/runuser', ['-u', 'caboose', '--', '/bin/sh', '-c', launchScript(agent), 'sh', dir], 15_000)
    const task: AgentTask = { id, agent, prompt, status: 'running', startedAt: new Date().toISOString() }
    this.tracked.set(id, { task, offset: 0, carry: '' })
    this.releases.set(id, this.acquire())
    this.emit({ type: 'agent.task.started', id, agent, prompt })
    this.ensurePolling()
    return task
  }

  async cancel(id: string): Promise<boolean> {
    const entry = this.tracked.get(id)
    const guest = this.guest()
    if (!entry || !TASK_ID.test(id) || entry.task.status !== 'running' || !guest) return false
    await guest.run('/bin/sh', ['-c', 'pid=$(cat "$1/pid" 2>/dev/null) && kill -TERM -- -"$pid" 2>/dev/null || kill -TERM "$pid" 2>/dev/null || true',
      'sh', `${HOME}/Agents/${id}`], 15_000)
    this.finish(entry, 'cancelled', 'Cancelled.')
    return true
  }

  /** Stops tailing (the computer is parking); running tasks resume being tailed on wake. */
  pause(): void {
    if (this.timer) clearInterval(this.timer)
    this.timer = undefined
  }

  resume(): void {
    if ([...this.tracked.values()].some(entry => entry.task.status === 'running')) this.ensurePolling()
  }

  private ensurePolling(): void {
    if (this.timer) return
    this.timer = setInterval(() => { void this.poll() }, this.pollMs)
    this.timer.unref()
  }

  async poll(): Promise<void> {
    const guest = this.guest()
    if (this.polling || !guest) return
    this.polling = true
    try {
      for (const entry of this.tracked.values()) {
        if (entry.task.status !== 'running') continue
        const dir = `${HOME}/Agents/${entry.task.id}`
        const chunk = await guest.run('/bin/sh', ['-c',
          'tail -c +"$(( $2 + 1 ))" "$1/transcript.jsonl" 2>/dev/null | head -c 1048576; printf "\\n__CABOOSE__%s:%s" "$(cat "$1/exit-code" 2>/dev/null)" "$(cat "$1/stderr.log" 2>/dev/null | tail -c 400 | tr "\\n" " ")"',
          'sh', dir, String(entry.offset)], 15_000).catch(() => undefined)
        if (chunk === undefined) continue
        const marker = chunk.lastIndexOf('\n__CABOOSE__')
        const data = marker >= 0 ? chunk.slice(0, marker) : chunk
        const [exitCode, ...stderrParts] = (marker >= 0 ? chunk.slice(marker + 12) : ':').split(':')
        entry.offset += Buffer.byteLength(data)
        const lines = (entry.carry + data).split('\n')
        entry.carry = lines.pop() ?? ''
        let result: { ok: boolean; summary: string } | undefined
        for (const line of lines) {
          if (!line.trim()) continue
          const interpreted = interpretLine(line)
          for (const output of interpreted.outputs) {
            if (output.kind === 'text') entry.lastText = output.text
            this.emit({ type: 'agent.task.output', id: entry.task.id, ...output })
          }
          result ??= interpreted.result
        }
        if (result) this.finish(entry, result.ok ? 'succeeded' : 'failed', result.summary)
        else if (exitCode !== '') {
          const stderr = stderrParts.join(':').trim()
          const signedOut = /log ?in|sign ?in|authenticat|api key|unauthori[sz]ed/i.test(stderr)
          const summary = signedOut
            ? `${entry.task.agent === 'claude' ? 'Claude Code' : 'Codex'} is signed out. Open Terminal on your computer and run \`${entry.task.agent}\` once to sign in.`
            : exitCode === '0' ? entry.lastText ?? 'Done.' : stderr || `The agent exited with code ${exitCode}.`
          this.finish(entry, exitCode === '0' && !signedOut ? 'succeeded' : 'failed', summary)
        }
      }
    } finally {
      this.polling = false
      if (![...this.tracked.values()].some(entry => entry.task.status === 'running')) this.pause()
    }
  }

  private finish(entry: Tracked, status: TaskStatus, summary: string): void {
    if (entry.task.status !== 'running') return
    entry.task.status = status
    entry.task.finishedAt = new Date().toISOString()
    entry.task.summary = summary.slice(0, 2000)
    this.releases.get(entry.task.id)?.()
    this.releases.delete(entry.task.id)
    this.emit({ type: 'agent.task.finished', id: entry.task.id, status, summary: entry.task.summary })
  }
}

export class AgentInputError extends Error {}
export class AgentUnavailableError extends Error {
  constructor() { super('computer is not running') }
}
