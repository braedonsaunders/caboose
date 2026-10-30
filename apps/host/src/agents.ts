import type { EventSubscribe } from './event-adapters.js'
import { modelId, publicModels, type AgentModels } from './agent-models.js'
import { createHash, randomUUID } from 'node:crypto'
import { CONFIRM_JOURNAL, emptyJournal, JOURNAL_LIMIT, MAX_OPERATIONS, operationId, PUBLISH_PROMPT, READ_DELIVERY, readJournal, readPublishedPrompt, UUID, WRITE_JOURNAL, type DeliveryJournal, type QueuedReply, type StoredAttachment } from './agent-delivery.js'
import type { HomeOwnership } from './home.js'
import { decodeBase64, sanitizeFileName, uniqueName, writeGuestFile } from './files.js'
import type { AgentLaunch } from './registry.js'
import { AGENT_DISPLAY_ENV_PATH } from './display.js'
import type { AgentToolJournal } from './agent-tools-journal.js'
import { acceptAgentTools } from './agent-tools-mailbox.js'

/**
 * Agent tasks: any Agent Client Protocol (ACP) agent from the registry, run inside the
 * owner's computer as user `caboose` on the agent seat (its own Caboose Display, X display
 * :101, environment in /run/caboose/agent-display.env) by the guest's runner,
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

export interface AgentDraft { turn: number; kind: 'text' | 'thought'; text: string }

export interface AgentProfileSnapshot { id: string; instructions: string; workspace: string }
export interface AgentStartOptions { id?: string; profile?: AgentProfileSnapshot }

export interface AgentTask {
  requestedModel?: string
  models?: AgentModels
  /** Persistent identity; conversations still have their own ids and transcripts. */
  profileId?: string
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
  /** Replies sent while the agent was working, oldest first; they go to it together as its next turn. */
  queued?: string[]
  /** File paths for each waiting reply, in the same order as queued. */
  queuedAttachments?: string[][]
  draft?: AgentDraft
  /** A claimed or possibly delivered turn stopped without a durable result; never replayed automatically. */
  delivery?: { turn: number; state: 'uncertain'; message: string }
}

export type AgentEvent =
  | { type: 'agent.task.started'; id: string; agent: string; agentName?: string; prompt: string }
  | { type: 'agent.task.output'; id: string; kind: 'text' | 'tool' | 'error'; text: string }
  | { type: 'agent.task.deleted'; id: string }
  | { type: 'agent.task.paused'; id: string }
  | { type: 'agent.task.resumed'; id: string }
  | { type: 'agent.task.finished'; id: string; status: TaskStatus; summary: string; signIn?: SignInMethod[] }
  | { type: 'agent.task.approval'; id: string; request: PendingApproval }
  | { type: 'agent.task.approval.resolved'; id: string; requestId: string; allow: boolean }
  | { type: 'agent.task.replied'; id: string; prompt: string; turn: number }
  /** The replies waiting for the agent's turn to end changed. */
  | { type: 'agent.task.queued'; id: string; queued: string[]; queuedAttachments?: string[][] }
  | { type: 'agent.task.draft'; id: string; draft: AgentDraft | null }
  /** One entry of the current turn's transcript, as `GET /v1/agent/tasks/:id/transcript` returns them. */
  | { type: 'agent.task.event'; id: string; turn: number; entry: TranscriptEntry }

/**
 * One line of a task's transcript as clients see it: the runner's event (guest/agentd/README.md),
 * checked and trimmed, without session bookkeeping.
 */
export type TranscriptEntry = { at?: string } & (
  | { type: 'user'; turn: number; text: string; attachments?: string[] }
  | { type: 'text' | 'thought' | 'notice'; text: string }
  | { type: 'tool'; toolId: string; title: string; kind: string; status: string; detail?: string }
  | { type: 'tool_update'; toolId: string; title: string; kind: string; status: string }
  | { type: 'plan'; entries: Array<{ content: string; status: string }> }
  | { type: 'permission'; requestId: string | null; tool: string; summary: string; auto: boolean }
  | { type: 'permission_resolved'; requestId: string; allow: boolean; message?: string }
  | { type: 'usage'; used: number; size: number; cost?: { amount: number; currency: string } }
  | { type: 'turn_end'; turn: number; stopReason: string; summary: string }
  | { type: 'turn_failed' | 'auth_required'; turn: number; message: string })

export interface AgentGuest {
  /** Runs a command in the guest as root; resolves stdout, rejects on non-zero exit. */
  run(command: string, args: string[], timeoutMs?: number): Promise<string>
  /**
   * What a GUI started on the owner's display needs, as `KEY=value` pairs: caboose-display's
   * launch environment (its Wayland socket, Xwayland's display and cookie, toolkit hints),
   * read from /run/caboose/display.env at each wake. Empty until the display is ready.
   */
  ownerEnv?: string[]
}

/** Which agent a task runs, and how. Implemented by AgentCatalog over the ACP registry. */
export interface AgentResolver {
  /** The launch spec for a registry id; throws AgentNotFoundError or AgentInputError. */
  launch(id: string): Promise<AgentLaunch>
  /** The owner's default agent, or null when none is chosen. */
  defaultAgent(): string | null
  /** Advertised choices for a chat created before model state was recorded. */
  models?(id: string): Promise<{ models?: AgentModels }>
}

export interface AgentTaskOptions {
  resolver: AgentResolver
  /** Enables profile tools only after a host-owned binding is persisted. */
  toolJournal?: () => Promise<AgentToolJournal | null>
  craftServers?: () => Promise<Array<{ name: string; command: string; args: string[]; env: Array<{ name: string; value: string }> }>>
  /**
   * Brings the computer's MCP Library up to date before a runner starts, and says whether new
   * chats get it (the `caboose-library` server). Its secrets never enter the task's records.
   */
  mcpLibrary?: () => Promise<boolean>
  subscribe?: EventSubscribe
  eventsChanged?: () => void
  pollMs?: number
  /** Starts the agent seat's display; defaults to the microVM's systemd unit. */
  ensureSeat?: () => Promise<void>
  /** How long a runner keeps an agent and its session after a turn, waiting for a reply. */
  idleMs?: number
  /** Gives root-owned leftovers in the home back to caboose before a runner starts. */
  home?: HomeOwnership
}

const READ_MODEL_STATE = `const fs=require('fs'),p=require('path'),d=process.argv[1];
function read(n){try{const f=p.join(d,n);if(fs.statSync(f).size>262144)return {};return JSON.parse(fs.readFileSync(f,'utf8'))}catch{return {}}}
const state=read('models.json'),config=read('task.json'),requested=read('requested-model.json');
console.log(JSON.stringify({...state,requestedModel:typeof requested==='string'?requested:state.requestedModel??config.model}));`

/** Retire only this task's idle pre-model runner before publishing a selected-model reply. */
const RETIRE_MODEL_RUNNER = `// retire-model-runner
const fs=require('fs'),d=process.argv[1];
(async()=>{
const pid=Number(fs.readFileSync(d+'/pid','utf8').trim());if(!Number.isSafeInteger(pid)||pid<2)throw Error('Invalid runner pid');
let args,cwd;try{args=fs.readFileSync('/proc/'+pid+'/cmdline','utf8').split('\\0');cwd=fs.readlinkSync('/proc/'+pid+'/cwd')}catch(e){if(e.code==='ENOENT')return;throw e}
if(!args.join(' ').includes('caboose-agentd.mjs run')||cwd!==d)throw Error('Cannot identify this chat runner');
try{process.kill(-pid,'SIGTERM')}catch(e){if(e.code==='ESRCH')return;throw e}
for(let i=0;i<50;i++){try{const stat=fs.readFileSync('/proc/'+pid+'/stat','utf8');if(stat.slice(stat.lastIndexOf(')')+2).startsWith('Z'))return}catch(e){if(e.code==='ENOENT')return;throw e}await new Promise(r=>setTimeout(r,100))}
throw Error('The previous agent session is still stopping; try again');
})().catch(e=>{console.error(e.message);process.exitCode=1});`

/** Durably unpublish history only after the identified runner group has exited. */
export const DELETE_TASK = `// delete-agent-task
const fs=require('fs'),p=require('path'),d=process.argv[1],gone=p.join(p.dirname(d),'.deleted-'+p.basename(d));
function exists(f){try{return fs.lstatSync(f)}catch(e){if(e.code==='ENOENT')return null;throw e}}
function members(group){return fs.readdirSync('/proc').filter(n=>/^\\d+$/.test(n)).filter(n=>{try{const s=fs.readFileSync('/proc/'+n+'/stat','utf8');const f=s.slice(s.lastIndexOf(')')+2).split(' ');return Number(f[2])===group&&f[0]!=='Z'}catch(e){if(e.code==='ENOENT'||e.code==='ESRCH')return false;throw e}})}
(async()=>{
if(exists(d)){
if(!exists(d).isDirectory()||exists(d).isSymbolicLink())throw Error('Invalid chat directory');
let pid;try{pid=Number(fs.readFileSync(d+'/pid','utf8').trim())}catch(e){if(e.code!=='ENOENT')throw e}
if(pid!==undefined){
if(!Number.isSafeInteger(pid)||pid<2)throw Error('Invalid runner pid');
const live=members(pid);
if(live.length){
let args,cwd;try{args=fs.readFileSync('/proc/'+pid+'/cmdline','utf8');cwd=fs.readlinkSync('/proc/'+pid+'/cwd')}catch{throw Error('Cannot identify this chat runner')}
if(!args.includes('caboose-agentd.mjs run')||cwd!==d)throw Error('Cannot identify this chat runner');
for(const signal of ['SIGTERM','SIGCONT'])try{process.kill(-pid,signal)}catch(e){if(e.code!=='ESRCH')throw e}
for(let i=0;i<50&&members(pid).length;i++)await new Promise(r=>setTimeout(r,100));
if(members(pid).length)throw Error('The agent is still stopping; try again');
}}
}
fs.mkdirSync(gone,{recursive:true});const fd=fs.openSync(p.dirname(d),'r');try{fs.fsyncSync(fd)}finally{fs.closeSync(fd)}
if(exists(gone)&&exists(d)){
if(!exists(gone).isDirectory()||exists(gone).isSymbolicLink())throw Error('Invalid deleted chat directory');
for(const name of ['prompt.txt','task.json','transcript.jsonl','draft.json','delivery.json','initial-prompt.json','session','models.json','requested-model.json','agent.log','stderr.log','pid','exit-code','agent','agent-name','approval-mode','turns','profile-id','profile-instructions.txt','tool-turn','tool-mailbox','inbox','approvals','receipts','deliveries'])fs.rmSync(p.join(d,name),{recursive:true,force:true});
for(const name of fs.readdirSync(d))if(/^(?:\\.delivery-input-[0-9a-f-]{36}\\.json|delivery\\.json\\.[0-9a-f-]{36}\\.tmp|\\.(?:models|draft)\\.json\\.[0-9]+\\.tmp)$/.test(name))fs.rmSync(p.join(d,name),{force:true});
const fd=fs.openSync(d,'r');try{fs.fsyncSync(fd)}finally{fs.closeSync(fd)}
}
})().catch(e=>{console.error(e.message);process.exitCode=1});`

const HOME = '/home/caboose'
const RUNUSER = '/usr/sbin/runuser'
export const AGENTD = '/opt/caboose/agentd/caboose-agentd.mjs'
/** What the guest scripts print when the computer's image has no runner. */
export const RUNNER_MISSING = 'caboose-agentd is not installed in this computer'
const TASK_ID = UUID
/** The summary of a task that ran before caboose-agentd (no task.json). */
export const LEGACY_SUMMARY = 'Ran before Caboose\'s agent runner, so it cannot be continued. Its transcript is in'
const AGENT_ID = /^[a-z0-9][a-z0-9._-]{0,63}$/
/** Approval request ids are UUIDs minted by caboose-agentd. */
const REQUEST_ID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/
const MAX_PROMPT = 32_000
const MAX_ATTACHMENTS = 4
/** Replies that can wait for a working agent. */
const MAX_QUEUED = 10
const MAX_ATTACHMENT_BYTES = 10 * 1024 * 1024
/** Transcript bytes read per poll tick across all live tasks, shared between them. */
const POLL_BUDGET = 1024 * 1024
const MIN_TASK_CHUNK = 64 * 1024
const DEFAULT_IDLE_MS = 10 * 60_000
/** The most of a transcript `transcript()` reads, from its end. */
const TRANSCRIPT_LIMIT = 2 * 1024 * 1024
/** Clients that predate the registry name the two agents they knew. */
const LEGACY_AGENTS: Readonly<Record<string, string>> = { claude: 'claude-acp', codex: 'codex-acp' }

const LAUNCH = [
  // The seat's launch environment (its Wayland socket, Xwayland :101 and cookie, control socket), when it is up.
  `if [ -r ${AGENT_DISPLAY_ENV_PATH} ]; then set -a; . ${AGENT_DISPLAY_ENV_PATH}; set +a; fi`,
  // GUI profiles belong to wrappers; preserve the runner CLI authentication home.
  'unset XDG_CONFIG_HOME XDG_DATA_HOME XDG_CACHE_HOME XDG_STATE_HOME CABOOSE_SEAT MOZ_NO_REMOTE VSCODE_PORTABLE CHROME_CONFIG_HOME CHROME_USER_DATA_DIR VSCODE_IPC_HOOK_CLI',
  'export HOME=/home/caboose DISPLAY=:101 XDG_RUNTIME_DIR=/run/user/1000 DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/agent-bus PATH=/usr/local/libexec/caboose-agent-seat-bin:/home/caboose/.local/bin:/usr/local/bin:/usr/bin:/bin CABOOSE_TASK_DIR="$PWD"',
  `[ -f ${AGENTD} ] || { echo "${RUNNER_MISSING}" >&2; exit 1; }`,
  'rm -f exit-code',
  `setsid sh -c 'node ${AGENTD} run "$PWD" >> stderr.log 2>&1; echo $? > exit-code' > /dev/null 2>&1 < /dev/null &`,
  'echo $! > pid',
]

/**
 * Admits a staged task directory and starts its runner as `caboose`: $1 final directory,
 * $2 original prompt, $3 agent id, $4 name, $5 approval mode, $6 task.json, $7 prompt file
 * reference, $8 journal, $9 journal writer, $10 publisher, $11 staging directory. Attachments
 * and the prompt input are staged first; directory rename precedes runner launch.
 */
export const START_SCRIPT = [
  'set -e',
  '[ ! -e "$(dirname \"$1\")/.deleted-$(basename \"$1\")" ] || { echo "task was deleted" >&2; exit 1; }',
  'mkdir -p "${11}/inbox" "${11}/approvals"',
  'cd "${11}"',
  'printf %s "$2" > prompt.txt && printf %s "$3" > agent && printf %s "$4" > agent-name && printf %s "$5" > approval-mode && printf 1 > turns',
  'printf %s "$6" > task.json',
  'sync -f task.json',
  'node -e "$9" "${11}/delivery.json" "$8"',
  'node -e "${10}" "${11}" "$7" 000001',
  '[ ! -e "$1" ] || { echo "task already exists" >&2; exit 1; }',
  'mv -T -- "${11}" "$1"',
  'sync -f "$1"',
  'cd "$1"',
  ...LAUNCH,
].join('\n')

/**
 * A reply: $2 the staged prompt reference, $3 the turn number, $4 its six-digit inbox name,
 * $5 the publisher. Publication never recreates an inbox behind an existing marker. A runner
 * still waiting after the last turn takes the prompt from its inbox; otherwise (it exited, or
 * did not take it within 20 s and is stopped) a new runner starts and takes it.
 */
export const REPLY_SCRIPT = [
  'set -e',
  'cd "$1"',
  'node -e "$5" "$1" "$2" "$4"',
  'printf %s "$3" > turns',
  'pid=$(cat pid 2>/dev/null || true)',
  'if [ -n "$pid" ] && [ ! -e exit-code ] && kill -0 "$pid" 2>/dev/null; then',
  '  for i in $(seq 1 100); do',
  '    [ -e "receipts/$4.json" ] && { echo claimed; exit 0; }',
  '    [ -e "inbox/$4.prompt.json" ] || { echo uncertain; exit 0; }',
  '    kill -0 "$pid" 2>/dev/null || break',
  '    sleep 0.2',
  '  done',
  '  if kill -0 "$pid" 2>/dev/null; then kill -TERM -- -"$pid" 2>/dev/null || kill -TERM "$pid" 2>/dev/null || true; sleep 1; fi',
  '  kill -0 "$pid" 2>/dev/null && { echo waiting; exit 0; }',
  'fi',
  '[ -e "receipts/$4.json" ] && { echo claimed; exit 0; }',
  '[ -e "inbox/$4.prompt.json" ] || { echo uncertain; exit 0; }',
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
export interface TurnResult { finishedAt?: string; uncertain?: boolean; turn: number; status: 'succeeded' | 'failed' | 'cancelled'; summary: string; signIn?: SignInMethod[] }

/**
 * Turns one line of the runner's transcript into display events, the start of a turn, or a
 * turn's result. The transcript is the same for every agent (guest/agentd/README.md).
 */
export function interpretLine(line: string): { outputs: Output[]; turn?: number; result?: TurnResult } {
  let event: any
  try { event = JSON.parse(line) } catch { return { outputs: [] } }
  const turn = Number.isSafeInteger(event?.turn) ? event.turn as number : undefined
  const timestamp = typeof event?.at === 'string' && event.at.length <= 40 ? Date.parse(event.at) : NaN
  const completion = Number.isFinite(timestamp) && timestamp <= Date.now() ? { finishedAt: new Date(timestamp).toISOString() } : {}
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
      return { outputs: [], result: { ...completion, turn, status, summary: typeof event.summary === 'string' && event.summary ? event.summary : 'Done.' } }
    }
    case 'turn_failed': {
      if (turn === undefined) return { outputs: [] }
      const message = typeof event.message === 'string' && event.message ? event.message : 'The agent failed.'
      return { outputs: [{ kind: 'error', text: message }], result: { ...completion, turn, status: 'failed', summary: message, ...(event.uncertain === true ? { uncertain: true } : {}) } }
    }
    case 'auth_required': {
      if (turn === undefined) return { outputs: [] }
      const signIn = readSignIn(event.authMethods)
      return { outputs: [], result: { ...completion, turn, status: 'failed', summary: '', signIn } }
    }
    default:
      return { outputs: [] }
  }
}

function readSignIn(value: unknown): SignInMethod[] {
  if (!Array.isArray(value)) return []
  return value.slice(0, 20).flatMap(item => {
    if (!item || typeof item.id !== 'string' || typeof item.name !== 'string' || (item.type !== 'agent' && item.type !== 'terminal')) return []
    return [{ id: item.id.slice(0, 200), name: item.name.slice(0, 200), ...(typeof item.description === 'string' && item.description ? { description: item.description.slice(0, 500) } : {}), type: item.type }]
  })
}

const TEXT_LIMIT = 16_000

/** The runner's transcript line as a client entry; undefined for bookkeeping and lines it cannot read. */
export function transcriptEntry(line: string): TranscriptEntry | undefined {
  let event: any
  try { event = JSON.parse(line) } catch { return undefined }
  if (!event || typeof event !== 'object') return undefined
  const text = (value: unknown, limit = TEXT_LIMIT) => typeof value === 'string' ? value.slice(0, limit) : ''
  const turn = Number.isSafeInteger(event.turn) ? event.turn as number : undefined
  const at = typeof event.at === 'string' ? { at: event.at.slice(0, 40) } : {}
  switch (event.type) {
    case 'user': {
      if (turn === undefined) return undefined
      const attachments = Array.isArray(event.attachments) ? event.attachments.filter((path: unknown) => typeof path === 'string').slice(0, 4) : []
      return { type: 'user', ...at, turn, text: text(event.text, 32_000), ...(attachments.length ? { attachments } : {}) }
    }
    case 'text': case 'thought': case 'notice':
      return text(event.text).trim() ? { type: event.type, ...at, text: text(event.text) } : undefined
    case 'tool': case 'tool_update': {
      if (typeof event.id !== 'string' || !event.id) return undefined
      const base = { ...at, toolId: event.id.slice(0, 200), title: text(event.title, 500) || 'Tool', kind: text(event.kind, 40) || 'other', status: text(event.status, 40) || 'pending' }
      if (event.type === 'tool_update') return { type: 'tool_update', ...base }
      return { type: 'tool', ...base, ...(typeof event.detail === 'string' && event.detail ? { detail: event.detail.slice(0, 1000) } : {}) }
    }
    case 'plan':
      return {
        type: 'plan', ...at,
        entries: Array.isArray(event.entries) ? event.entries.slice(0, 50).map((entry: any) => ({ content: text(entry?.content, 500), status: text(entry?.status, 40) || 'pending' })) : [],
      }
    case 'permission':
      return {
        type: 'permission', ...at, requestId: typeof event.requestId === 'string' && REQUEST_ID.test(event.requestId) ? event.requestId : null,
        tool: text(event.tool, 200) || 'Tool', summary: text(event.summary, 300), auto: event.auto === true,
      }
    case 'permission_resolved':
      if (typeof event.requestId !== 'string' || !REQUEST_ID.test(event.requestId)) return undefined
      return { type: 'permission_resolved', ...at, requestId: event.requestId, allow: event.allow === true, ...(typeof event.message === 'string' && event.message ? { message: event.message.slice(0, 2000) } : {}) }
    case 'usage': {
      if (!Number.isFinite(event.used) || !Number.isFinite(event.size)) return undefined
      const cost = event.cost && Number.isFinite(event.cost.amount) && typeof event.cost.currency === 'string' ? { cost: { amount: event.cost.amount as number, currency: event.cost.currency.slice(0, 10) } } : {}
      return { type: 'usage', ...at, used: event.used, size: event.size, ...cost }
    }
    case 'turn_end':
      if (turn === undefined) return undefined
      return { type: 'turn_end', ...at, turn, stopReason: text(event.stopReason, 40) || 'end_turn', summary: text(event.summary, 2000) }
    case 'turn_failed': case 'auth_required':
      if (turn === undefined) return undefined
      return { type: event.type, ...at, turn, message: text(event.message, 2000) }
    default:
      return undefined
  }
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
  lastEventDigest?: string
  discardLine?: boolean
  carry: Buffer
  /** The turn the transcript is in, by its latest `user` line; output of older turns is not shown. */
  turn: number
  /** Started by the runner (task.json exists), so a reply can continue it. */
  resumable: boolean
  /** Approval requests the agent is waiting on, oldest first. */
  pending: Array<PendingApproval & { requestedAt: string }>
  replying?: boolean
  /** A validated mirror of the guest journal; changed only on the task operation chain. */
  queue: QueuedReply[]
  journal: DeliveryJournal
  journalError?: string
  completedTurn?: number
  deleting?: boolean
  replyChain?: Promise<unknown>
}

export class AgentTasks {
  private readonly tracked = new Map<string, Tracked>()
  private readonly releases = new Map<string, () => void>()
  private timer: (() => void) | undefined
  private eventGeneration = 0
  private readonly subscribe?: EventSubscribe
  private readonly eventsChanged?: () => void
  private polling = false
  private readonly resolver: AgentResolver
  private readonly toolJournal?: AgentTaskOptions["toolJournal"]
  private toolWork?: Promise<void>
  private readonly craftServers?: AgentTaskOptions["craftServers"]
  private readonly mcpLibrary?: AgentTaskOptions["mcpLibrary"]
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
    this.toolJournal = options.toolJournal
    this.craftServers = options.craftServers
    this.mcpLibrary = options.mcpLibrary
    this.subscribe = options.subscribe
    this.eventsChanged = options.eventsChanged
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
    this.needsRecovery = true
    for (const entry of this.tracked.values()) {
      if (isLive(entry.task.status)) this.finish(entry, 'failed', 'Stopped when the computer restarted.', false)
    }
  }

  private startChain: Promise<unknown> = Promise.resolve()

  async start(input: Record<string, unknown>, options?: AgentStartOptions): Promise<AgentTask> {
    if (options?.id !== undefined && (typeof options.id !== 'string' || !UUID.test(options.id))) throw new AgentInputError('id must be a canonical UUID')
    const operation = this.startChain.catch(() => {}).then(() => this.startTask(input, options))
    this.startChain = operation
    return operation
  }

  private async startTask(input: Record<string, unknown>, options?: AgentStartOptions): Promise<AgentTask> {
    const stableId = options?.id
    const profile = options?.profile
    if (profile && (!UUID.test(profile.id) || profile.workspace !== `${HOME}/AgentWorkspaces/${profile.id}` ||
      typeof profile.instructions !== 'string' || profile.instructions.includes('\0') || profile.instructions.length > 100_000)) {
      throw new AgentInputError('Invalid persistent agent snapshot')
    }
    if (input.profileId !== undefined && input.profileId !== profile?.id) throw new AgentInputError('Resolve the agent profile before starting a task')
    const requestedModel = modelId(input.model)
    const prompt = readPrompt(input.prompt)
    const approvals = input.approvals === 'ask' ? 'ask' : input.approvals === 'auto' || input.approvals === undefined ? 'auto' : undefined
    if (!approvals) throw new AgentInputError('approvals must be "ask" or "auto"')
    if (input.craftMcp !== undefined && typeof input.craftMcp !== 'boolean') throw new AgentInputError('craftMcp must be a boolean')
    const files = readAttachments(input.attachments)
    const guest = this.guest()
    if (!guest) throw new AgentUnavailableError()
    const original = fingerprint(input, files, true, profile)
    const id = stableId ?? randomUUID()
    if (stableId) {
      await this.restoring
      await this.restoreId(id)
      const existing = this.tracked.get(id)
      if (existing) {
        if (existing.journalError || existing.journal.original !== original) throw new AgentConflictError('Task id already exists with a different original payload or unreadable admission.')
        await this.serial(existing, async () => { await this.save(existing, existing.journal); await this.recoverDelivery(existing) })
        return existing.task
      }
    }
    const agentId = this.readAgent(input.agent)
    const launch = await this.resolver.launch(agentId)
    const journal: DeliveryJournal = { ...emptyJournal(), original, turns: 1, intent: { id: randomUUID(), turn: 1, replies: [] } }
    const toolJournal = profile && this.toolJournal ? await this.toolJournal() : null
    if (profile && toolJournal) await toolJournal.bindTask(id, profile.id)
    const dir = `${HOME}/Agents/${id}`
    const staging = `${HOME}/Agents/.${id}.${randomUUID()}`
    const attachments = files.map(file => `${dir}/attachments/${file.name}`)
    journal.startAttachments = attachments
    await this.prepareSeat(guest)
    try {
      for (const file of files) {
        const staged = `${staging}/attachments/${file.name}`
        await writeGuestFile(guest, `${staged}.part`, file.data)
        await asCaboose(guest, 'mv -- "$1.part" "$1" && sync -f "$1"', [staged])
      }
      const craftServers = input.craftMcp === false ? [] : await this.craftServers?.() ?? []
      // A Library that cannot be brought up to date is left out of this chat, not fatal to it.
      const library = await this.mcpLibrary?.().catch(error => { console.error('MCP Library unavailable for a new chat:', error instanceof Error ? error.message : error); return false }) ?? false
      if (profile) {
        await asCaboose(guest, 'mkdir -p -- "$1"', [profile.workspace])
        await writeGuestFile(guest, `${staging}/profile-id`, Buffer.from(profile.id))
        await writeGuestFile(guest, `${staging}/profile-instructions.txt`, Buffer.from(profile.instructions))
      }
      const config = JSON.stringify({ agent: launch, model: requestedModel, cwd: profile?.workspace ?? dir, approvals, idleMs: this.idleMs, craftServers,
        ...(library ? { mcpLibrary: true } : {}), ...(profile ? { profileId: profile.id } : {}), ...(toolJournal ? { agentTools: true } : {}) })
      const message = JSON.stringify({ type: 'prompt', turn: 1, deliveryId: journal.intent!.id, text: prompt,
        ...(files.length ? { attachments: files.map((file, index) => ({ path: attachments[index], name: file.name, ...(file.type ? { mimeType: file.type } : {}) })) } : {}) })
      await writeGuestFile(guest, `${staging}/initial-prompt.json`, Buffer.from(message))
      await asCaboose(guest, START_SCRIPT, [dir, prompt, agentId, launch.name, approvals, config, '@file:initial-prompt.json', JSON.stringify(journal), WRITE_JOURNAL, PUBLISH_PROMPT, staging]).catch(rethrowRunnerMissing)
    } catch (error) {
      // A failed command can have committed admission or launched the runner. Never erase it.
      throw error
    }
    const task: AgentTask = {
      id, ...(requestedModel ? { requestedModel } : {}), ...(profile ? { profileId: profile.id } : {}), agent: agentId, agentName: launch.name, prompt, status: 'running', startedAt: new Date().toISOString(), turns: 1, approvals,
      ...(attachments.length ? { attachments } : {}),
    }
    this.tracked.set(id, { task, offset: 0, carry: Buffer.alloc(0), turn: 0, resumable: true, pending: [], queue: [], journal })
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
   * Continues the task's conversation with a new prompt. A runner still waiting keeps the same
   * session; a new runner reopens it (session/resume or session/load) or, for an agent that can
   * do neither, starts a new one with a recap. The turn appends to the same transcript. While
   * the agent is working the reply waits in the task's queue; when the turn ends, everything
   * waiting goes to the agent together as its next turn.
   */
  async models(id: string, input?: Record<string, unknown>): Promise<{ requestedModel?: string; models?: AgentModels; currentModelKnown?: boolean }> {
    await this.restoring
    const entry = TASK_ID.test(id) ? this.tracked.get(id) : undefined
    if (!entry) throw new AgentNotFoundError()
    return this.serial(entry, async () => {
      const guest = this.guest()
      if (!guest) throw new AgentUnavailableError()
      const dir = `${HOME}/Agents/${id}`
      const raw = await asCaboose(guest, 'exec node -e "$2" "$1"', [dir, READ_MODEL_STATE])
      let state: any = {}; try { state = JSON.parse(raw) } catch {}
      const recordedModels = publicModels(state.models)
      const models = recordedModels ?? (!isLive(entry.task.status) && this.resolver.models
        ? publicModels((await this.resolver.models(entry.task.agent)).models) : undefined)
      if (models) entry.task.models = models
      if (typeof state.requestedModel === 'string') entry.task.requestedModel = modelId(state.requestedModel)
      if (input) {
        if (isLive(entry.task.status) || entry.queue.length) throw new AgentConflictError('Wait for the agent and its queued messages before changing models')
        const requested = modelId(input.model)
        if (!requested || !models?.availableModels.some(m => m.id === requested)) throw new AgentInputError('Choose a model advertised by this session')
        if (!recordedModels) {
          const evidence = await this.evidence(entry)
          if (evidence.alive) await asCaboose(guest, 'exec node -e "$2" "$1"', [dir, RETIRE_MODEL_RUNNER])
        }
        await asCaboose(guest, 'printf %s "$2" > "$1/requested-model.json.part" && sync -f "$1/requested-model.json.part" && mv "$1/requested-model.json.part" "$1/requested-model.json" && sync -f "$1"', [dir, JSON.stringify(requested)])
        entry.task.requestedModel = requested
      }
      return { ...(entry.task.requestedModel ? { requestedModel: entry.task.requestedModel } : {}), ...(models ? { models } : {}), ...(!recordedModels && models ? { currentModelKnown: false } : {}) }
    })
  }

  async reply(id: string, input: Record<string, unknown>): Promise<AgentTask> {
    await this.restoring
    await this.recovering
    const entry = TASK_ID.test(id) ? this.tracked.get(id) : undefined
    if (!entry) throw new AgentNotFoundError()
    return this.serial(entry, () => this.acceptReply(entry, input))
  }

  private serial<T>(entry: Tracked, step: () => Promise<T>): Promise<T> {
    const operation = (entry.replyChain ?? Promise.resolve()).catch(() => {}).then(() => {
      if (this.tracked.get(entry.task.id) !== entry) throw new AgentNotFoundError()
      return step()
    })
    entry.replyChain = operation
    return operation
  }

  private async save(entry: Tracked, journal: DeliveryJournal): Promise<void> {
    const guest = this.guest()
    if (!guest) throw new AgentUnavailableError()
    const text = JSON.stringify(journal)
    if (Buffer.byteLength(text) > JOURNAL_LIMIT) throw new AgentConflictError('This task has reached its durable journal limit; start a new task.')
    try {
      await asCaboose(guest, 'dir=$1; code=$2; shift 2; exec node -e "$code" "$dir/delivery.json" @base64 "$@"', [`${HOME}/Agents/${entry.task.id}`, WRITE_JOURNAL, ...Buffer.from(text).toString('base64').match(/.{1,48000}/g)!])
    } catch (error) {
      // A timeout after rename is ambiguous. Adopt only the exact committed snapshot.
      const evidence = await this.evidence(entry).catch(() => undefined)
      if (!evidence) entry.journalError = 'Cannot confirm durable admission; restart recovery before changing this task.'
      if (evidence?.journal !== text) throw error
      try {
        const confirmed = await asCaboose(guest, 'exec node -e "$2" "$1/delivery.json" "$3"',
          [`${HOME}/Agents/${entry.task.id}`, CONFIRM_JOURNAL, createHash('sha256').update(text).digest('hex')])
        if (confirmed.trim() !== 'confirmed') throw new Error('No durability acknowledgement')
      } catch {
        entry.journalError = 'Cannot confirm durable admission; restart recovery before changing this task.'
        throw error
      }
    }
    entry.journal = journal
    entry.queue = journal.queue
  }

  private async evidence(entry: Tracked): Promise<{ journal: string; receipt: string; receiptExists: boolean; inbox: string; published: string; transcript: string; alive: boolean }> {
    const guest = this.guest()
    if (!guest) throw new AgentUnavailableError()
    const out = await asCaboose(guest, 'exec node -e "$2" "$1" "$3"', [`${HOME}/Agents/${entry.task.id}`, READ_DELIVERY,
      entry.journal.intent ? String(entry.journal.intent.turn).padStart(6, '0') : ''])
    const value = JSON.parse(out)
    if (!value || ['journal', 'receipt', 'inbox', 'published', 'transcript'].some(key => typeof value[key] !== 'string') || typeof value.alive !== 'boolean' || typeof value.receiptExists !== 'boolean') throw new Error('Invalid delivery evidence')
    return value
  }

  private async acceptReply(entry: Tracked, input: Record<string, unknown>): Promise<AgentTask> {
    const prompt = readPrompt(input.prompt)
    const files = readAttachments(input.attachments)
    if (input.operationId !== undefined && !operationId(input.operationId)) throw new AgentInputError('operationId must be 1–200 characters without control characters')
    if (!entry.resumable) throw new AgentConflictError('This task was started by an earlier version of Caboose and cannot be continued.')
    if (entry.journalError) throw new AgentConflictError(entry.journalError)
    const key = typeof input.operationId === 'string' ? input.operationId : randomUUID()
    const hash = fingerprint(input, files)
    const previous = entry.journal.operations.find(op => op.id === key)
    if (previous) {
      if (previous.hash !== hash) throw new AgentConflictError('operationId already exists with a different original payload')
      // A retry can follow an earlier ambiguous fsync failure; establish durability again.
      await this.save(entry, entry.journal)
      await this.recoverDelivery(entry)
      if (!isLive(entry.task.status) && !entry.task.delivery && entry.queue.length) {
        try { await this.sendTurn(entry) } catch (error) { console.error('Admitted reply awaits delivery:', error) }
      }
      return entry.task
    }
    if (entry.journal.operations.length >= MAX_OPERATIONS) throw new AgentConflictError('This task has reached its durable operation limit; start a new task.')
    const guest = this.guest()
    if (!guest) throw new AgentUnavailableError()
    const attachments = entry.queue.flatMap(reply => reply.attachments)
    if (entry.queue.length >= MAX_QUEUED || [...entry.queue.map(reply => reply.prompt), prompt].join('\n\n').length > MAX_PROMPT
        || attachments.length + files.length > MAX_ATTACHMENTS
        || attachments.reduce((n, file) => n + file.bytes, 0) + files.reduce((n, file) => n + file.data.length, 0) > MAX_ATTACHMENT_BYTES) {
      throw new AgentConflictError('Too much is already waiting for the agent; wait for its turn to end, or stop it.')
    }
    const dir = `${HOME}/Agents/${entry.task.id}/attachments/${randomUUID()}`
    const staged: StoredAttachment[] = []
    for (const file of files) {
      const path = `${dir}/${file.name}`
      await writeGuestFile(guest, `${path}.part`, file.data)
      await asCaboose(guest, 'mv -- "$1.part" "$1" && sync -f "$1"', [path])
      staged.push({ path, name: file.name, bytes: file.data.length, ...(file.type ? { mimeType: file.type } : {}) })
    }
    // Admission is durable before any success response or attempt to deliver.
    await this.save(entry, { ...entry.journal, queue: [...entry.queue, { id: key, hash, prompt, attachments: staged }],
      operations: [...entry.journal.operations, { id: key, hash }] })
    this.syncQueue(entry)
    if (!isLive(entry.task.status) && !entry.task.delivery) {
      try { await this.sendTurn(entry) } catch (error) { console.error('Admitted reply awaits delivery:', error) }
    }
    return entry.task
  }

  /** Stops the current turn and delivers the durable queue. */
  async sendNow(id: string): Promise<AgentTask> {
    await this.restoring
    await this.recovering
    const entry = TASK_ID.test(id) ? this.tracked.get(id) : undefined
    if (!entry) throw new AgentNotFoundError()
    return this.serial(entry, async () => {
      if (entry.journalError) throw new AgentConflictError(entry.journalError)
      if (entry.journal.intent && entry.journal.intent.turn > entry.task.turns) {
        await this.recoverDelivery(entry)
        if (!entry.task.delivery && entry.task.turns === entry.journal.intent?.turn) return entry.task
      }
      if (entry.task.delivery) throw new AgentConflictError(entry.task.delivery.message)
      if (!entry.queue.length) throw new AgentConflictError('No messages are waiting.')
      entry.replying = true
      try {
        if (isLive(entry.task.status)) await this.cancelTurn(entry, false)
        return await this.sendTurn(entry, true)
      } catch (error) {
        if (!isLive(entry.task.status)) {
          this.releases.get(id)?.(); this.releases.delete(id); this.announceFinished(entry)
        }
        throw error
      } finally { entry.replying = false }
    })
  }

  /** The queue remains in the journal until positive claim/transcript evidence retires it. */
  private async sendTurn(entry: Tracked, cancelledCurrent = false): Promise<AgentTask> {
    if (entry.task.delivery) throw new AgentConflictError(entry.task.delivery.message)
    // A runner this turn starts reads the Library's access then; keep it current.
    await this.mcpLibrary?.().catch(() => false)
    if (entry.journal.intent) {
      const futureIntent = entry.journal.intent.turn > entry.task.turns
      await this.recoverDelivery(entry)
      if (entry.task.delivery) throw new AgentConflictError('Delivery is uncertain; inspect the transcript before continuing.')
      // Recovery can relaunch an unclaimed inbox without claiming it. That intent still
      // owns its replies; a new batch must never include them a second time. Send Now may
      // supersede a cancelled current turn only after its replies have left the queue.
      const intent = entry.journal.intent
      if (intent && (futureIntent || !cancelledCurrent || entry.queue.some(reply => intent.replies.includes(reply.id)))) return entry.task
    }
    if (!entry.queue.length) return entry.task
    const guest = this.guest()
    if (!guest) throw new AgentUnavailableError()
    const turn = Math.max(entry.task.turns, entry.journal.turns ?? 1) + 1
    if (turn > 999999) throw new AgentConflictError('Task turn limit reached')
    const intent = { id: randomUUID(), turn, replies: entry.queue.map(reply => reply.id) }
    await this.save(entry, { ...entry.journal, intent, turns: turn })
    entry.replying = true
    try {
      await this.prepareSeat(guest)
      await this.publish(entry)
    } finally { entry.replying = false }
    return entry.task
  }

  private async publish(entry: Tracked, original?: string): Promise<void> {
    const intent = entry.journal.intent!
    if (intent.turn === 1 && !original) throw new Error('The original admitted prompt is unavailable')
    const replies = entry.queue.filter(reply => intent.replies.includes(reply.id))
    const prompt = original ? readPublishedPrompt(original, entry.task.id, intent).text : replies.map(reply => reply.prompt).join('\n\n')
    const attachments = replies.flatMap(reply => reply.attachments).map(({ bytes: _bytes, ...file }) => file)
    const guest = this.guest()
    if (!guest) throw new AgentUnavailableError()
    // Turn 1 has no reply queue entries. Its admitted envelope owns original file names,
    // MIME types and paths, and must match the durable publication marker byte for byte.
    const message = original ?? JSON.stringify({ type: 'prompt', turn: intent.turn, deliveryId: intent.id, text: prompt, ...(attachments.length ? { attachments } : {}) })
    const file = `.delivery-input-${intent.id}.json`
    await writeGuestFile(guest, `${HOME}/Agents/${entry.task.id}/${file}`, Buffer.from(message))
    const outcome = await asCaboose(guest, REPLY_SCRIPT, [`${HOME}/Agents/${entry.task.id}`, `@file:${file}`, String(intent.turn), String(intent.turn).padStart(6, '0'), PUBLISH_PROMPT], 40_000).catch(rethrowRunnerMissing)
    this.markRunning(entry, intent.turn)
    if (['claimed', 'uncertain'].includes(outcome.trim())) await this.recoverDelivery(entry)
    this.emit({ type: 'agent.task.replied', id: entry.task.id, prompt, turn: intent.turn })
  }

  private markRunning(entry: Tracked, turn: number): void {
    const task = entry.task
    task.status = 'running'; task.turns = turn
    delete task.finishedAt; delete task.summary; delete task.pendingApproval; delete task.signIn
    entry.pending = []; this.setDraft(entry, null)
    // A published inbox is pending, not proof of delivery. Hide its batch from the waiting UI.
    this.syncQueue(entry)
    this.releases.get(task.id)?.(); this.releases.set(task.id, this.acquire())
    this.ensurePolling()
  }

  private async retireIntent(entry: Tracked): Promise<void> {
    const intent = entry.journal.intent
    if (!intent) return
    await this.save(entry, { ...entry.journal, turns: Math.max(entry.journal.turns ?? 1, intent.turn), intent: undefined, queue: entry.queue.filter(reply => !intent.replies.includes(reply.id)),
      operations: entry.journal.operations.map(op => intent.replies.includes(op.id) ? { ...op, turn: intent.turn } : op) })
    this.syncQueue(entry)
  }

  private async confirmClaim(entry: Tracked): Promise<void> {
    const intent = entry.journal.intent
    if (!intent || intent.claimed) return
    await this.save(entry, { ...entry.journal, intent: { ...intent, claimed: true },
      queue: entry.queue.filter(reply => !intent.replies.includes(reply.id)),
      operations: entry.journal.operations.map(op => intent.replies.includes(op.id) ? { ...op, turn: intent.turn } : op) })
    this.syncQueue(entry)
  }

  private async uncertain(entry: Tracked): Promise<void> {
    const intent = entry.journal.intent!
    const message = `Turn ${intent.turn} may have performed external actions before it stopped. Delivery is uncertain; inspect its transcript before continuing. This turn is not replayed.`
    await this.save(entry, { ...entry.journal, intent: { ...intent, uncertain: true } })
    entry.task.turns = Math.max(entry.task.turns, intent.turn)
    entry.task.delivery = { turn: intent.turn, state: 'uncertain', message }
    entry.task.status = 'running'
    this.finish(entry, 'failed', message, false)
    this.syncQueue(entry)
  }

  private async recoverDelivery(entry: Tracked, allowPublish = true, claimOnly = false): Promise<void> {
    const intent = entry.journal.intent
    if (!intent || entry.journalError) return
    const evidence = await this.evidence(entry)
    const events = evidence.transcript.split('\n').flatMap(line => { try { return [JSON.parse(line)] } catch { return [] } })
    const user = events.find(event => event?.type === 'user' && event.turn === intent.turn)
    let receipt: any
    try { receipt = JSON.parse(evidence.receipt) } catch { /* Older runners have no receipt. */ }
    const claimed = receipt?.deliveryId === intent.id && receipt?.turn === intent.turn && ['claimed', 'completed'].includes(receipt?.state)
    const result = events.map(event => interpretLine(JSON.stringify(event)).result).find(result => result?.turn === intent.turn)
      ?? (claimed && receipt.state === 'completed' ? interpretLine(JSON.stringify(receipt.result)).result : undefined)
    if (claimOnly) {
      if (claimed || user) await this.confirmClaim(entry)
      return
    }
    if (result?.turn === intent.turn) {
      const legacyFailure = !claimed && events.some(event => event?.type === 'turn_failed' && event.turn === intent.turn)
      if (result.uncertain || legacyFailure) { await this.uncertain(entry); return }
      entry.task.turns = Math.max(entry.task.turns, intent.turn)
      await this.retireIntent(entry)
      delete entry.task.delivery
      entry.task.status = 'running'; this.finishWith(entry, result, false, entry.queue.length > 0 && !result.signIn && result.status !== 'cancelled')
      return
    }
    if (intent.legacy) {
      if (!evidence.alive) await this.uncertain(entry)
      else if (!isLive(entry.task.status)) this.markRunning(entry, intent.turn)
      return
    }
    if (intent.uncertain || (!evidence.alive && (evidence.receiptExists || intent.claimed || claimed || user || evidence.published && !evidence.inbox))) {
      await this.uncertain(entry); return
    }
    if (claimed || user) {
      await this.confirmClaim(entry)
      // A runner can claim before the launch script updates `turns` or returns to the host.
      if (!isLive(entry.task.status) || entry.task.turns < intent.turn) this.markRunning(entry, intent.turn)
      return
    }
    if (evidence.receiptExists || evidence.published && !evidence.inbox) {
      // An old runner may be between unlink and its first transcript append. Wait while alive.
      if (!evidence.alive) await this.uncertain(entry)
      else if (!isLive(entry.task.status) || entry.task.turns < intent.turn) this.markRunning(entry, intent.turn)
      return
    }
    if (allowPublish && (!evidence.published || !evidence.alive && evidence.inbox)) await this.publish(entry, evidence.published || evidence.inbox || undefined)
    else if (allowPublish && evidence.inbox && (!isLive(entry.task.status) || intent.turn > entry.task.turns)) {
      this.markRunning(entry, intent.turn)
    }
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
    return this.serial(entry, async () => {
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
    this.emit({ type: 'agent.task.approval.resolved', id, requestId, allow: input.allow === true })
    return true
    })
  }

  /**
   * The task's conversation so far, read from its transcript in the guest: every turn, newest
   * last. Only the last TRANSCRIPT_LIMIT bytes are read; `truncated` says earlier lines were left out.
   */
  async transcript(id: string): Promise<{ entries: TranscriptEntry[]; truncated: boolean }> {
    const entry = TASK_ID.test(id) ? this.tracked.get(id) : undefined
    if (!entry) throw new AgentNotFoundError()
    const guest = this.guest()
    if (!guest) throw new AgentUnavailableError()
    const output = await asCaboose(guest, TRANSCRIPT_SCRIPT, [`${HOME}/Agents/${id}/transcript.jsonl`, String(TRANSCRIPT_LIMIT)], 20_000)
    const [size, data] = output.split('\t')
    const truncated = Number(size) > TRANSCRIPT_LIMIT
    const lines = decode(data).split('\n')
    // A cut-off read starts mid-line.
    if (truncated) lines.shift()
    const entries = lines.flatMap(line => {
      const parsed = line.trim() ? transcriptEntry(line) : undefined
      return parsed ? [parsed] : []
    })
    return { entries, truncated }
  }

  /** Cancels the running turn: the runner sends ACP session/cancel and answers waiting requests "cancelled". */
  async cancel(id: string): Promise<boolean> {
    const entry = this.tracked.get(id)
    const guest = this.guest()
    if (!entry || !TASK_ID.test(id) || !isLive(entry.task.status) || !guest) return false
    return this.serial(entry, () => this.cancelTurn(entry, true))
  }

  /** Removes this computer's history; a live chat requires explicit stop-and-delete. */
  async delete(id: string, stop = false): Promise<boolean> {
    if (!TASK_ID.test(id)) throw new AgentNotFoundError()
    await this.startChain.catch(() => {})
    await this.restore()
    const entry = this.tracked.get(id)
    const remove = async () => {
      const guest = this.guest()
      if (!guest) throw new AgentUnavailableError()
      if (entry && (isLive(entry.task.status) || entry.queue.length) && !stop) throw new AgentConflictError('Stop the agent before deleting this chat')
      if (entry) entry.deleting = true
      try {
        await this.toolWork
        await asCaboose(guest, 'exec node -e "$2" "$1"', [`${HOME}/Agents/${id}`, DELETE_TASK], 20_000)
        this.tracked.delete(id)
        this.eventsChanged?.()
        this.releases.get(id)?.(); this.releases.delete(id)
        this.emit({ type: 'agent.task.deleted', id })
        return true
      } finally { if (entry) entry.deleting = false }
    }
    return entry ? this.serial(entry, remove) : remove()
  }

  private async cancelTurn(entry: Tracked, drop: boolean): Promise<boolean> {
    const guest = this.guest()
    if (!guest) throw new AgentUnavailableError()
    await asCaboose(guest, CANCEL_SCRIPT, [`${HOME}/Agents/${entry.task.id}`])
    // Stopping stops everything: what was waiting for this turn is dropped with it.
    if (drop) {
      const hadQueue = entry.queue.length > 0
      await this.save(entry, { ...entry.journal, queue: [], intent: undefined, cancelled: entry.task.turns })
      delete entry.task.delivery
      this.syncQueue(entry, hadQueue)
    }
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
    return this.serial(entry, async () => {
      if (entry.task.status !== (paused ? 'running' : 'paused')) return false
      await guest.run('/bin/sh', ['-c', signal(paused ? 'STOP' : 'CONT'), 'sh', `${HOME}/Agents/${id}`], 15_000)
      entry.task.status = paused ? 'paused' : 'running'
      this.emit({ type: paused ? 'agent.task.paused' : 'agent.task.resumed', id })
      return true
    })
  }

  private async prepareSeat(guest: AgentGuest): Promise<void> {
    await this.home?.ensure(guest)
  }

  /**
   * Rebuilds the task list from the task directories in the guest, once per host process,
   * so a host restart neither forgets tasks nor drops the lease under one still running.
   */
  private restoring?: Promise<void>

  async restore(): Promise<void> {
    if (this.restoring) return this.restoring
    const guest = this.guest()
    if (this.restored || !guest) return
    const release = this.acquire()
    this.restoring = this.restoreId()
    try { await this.restoring; this.restored = true } finally { this.restoring = undefined; release() }
    this.resume()
  }

  private async restoreId(onlyId?: string): Promise<void> {
    const guest = this.guest()
    if (!guest) throw new AgentUnavailableError()
    const listing = await guest.run('/bin/sh', ['-c', RESTORE_SCRIPT, 'sh', `${HOME}/Agents`, onlyId ?? ''], 20_000)
    for (const line of listing.split('\n')) {
      const [id, agent, started, exitCode, alive, size, prompt, last, mode, turnsField, resumable, attached, name, profileId] = line.split('\t')
      if (!id || !TASK_ID.test(id) || this.tracked.has(id) || onlyId && id !== onlyId) continue
      const attachments = decode(attached).split('\n').filter(file => file && file.length <= 255 && !file.includes('/') && !/[\u0000-\u001f]/.test(file) && file !== '..' && file !== '.' && !file.endsWith('.part')).slice(0, MAX_ATTACHMENTS).map(file => `${HOME}/Agents/${id}/attachments/${file}`)
      let turns = Math.min(999999, Math.max(1, Number.parseInt(turnsField ?? '', 10) || 1))
      const agentId = agent && AGENT_ID.test(agent) ? LEGACY_AGENTS[agent] ?? agent : 'unknown'
      const agentName = decode(name).trim().slice(0, 100)
      const task: AgentTask = {
        id, ...(profileId && UUID.test(profileId) ? { profileId } : {}), agent: agentId, ...(agentName ? { agentName } : {}), prompt: decode(prompt).slice(0, MAX_PROMPT), status: 'running',
        startedAt: new Date(Number.isFinite(Number(started)) && Number(started) > 0 && Number(started) < 8640000000000 ? Number(started) * 1000 : 0).toISOString(),
        turns, approvals: mode === 'ask' ? 'ask' : 'auto',
        ...(attachments.length ? { attachments } : {}),
      }
      const entry: Tracked = { task, offset: Number.isSafeInteger(Number(size)) && Number(size) >= 0 ? Number(size) : 0, carry: Buffer.alloc(0), turn: turns, resumable: resumable === '1', pending: [], queue: [], journal: emptyJournal() }
      this.tracked.set(id, entry)
      try {
        const evidence = await this.evidence(entry)
        if (evidence.journal) {
          entry.journal = readJournal(evidence.journal, id)
          entry.queue = entry.journal.queue
          turns = Math.max(turns, entry.journal.turns ?? 1)
          task.turns = turns; entry.turn = turns
          if (entry.journal.startAttachments?.length) entry.task.attachments = entry.journal.startAttachments
          else if (entry.journal.startAttachments) delete entry.task.attachments
        } else if (entry.resumable) {
          // A pre-upgrade runner has no delivery token. Observe its current turn, never
          // synthesize an inbox for it, and persist this fence before admitting replies.
          await this.save(entry, { ...emptyJournal(), turns, intent: { id: randomUUID(), turn: turns, replies: [], legacy: true } })
        }
      } catch (error) {
        entry.journalError = error instanceof Error ? error.message : 'Cannot read durable replies'
      }
      try {
        const raw = await asCaboose(guest, 'exec node -e "$2" "$1"', [`${HOME}/Agents/${id}`, READ_MODEL_STATE])
        const state = JSON.parse(raw)
        task.models = publicModels(state.models)
        task.requestedModel = modelId(state.requestedModel)
      } catch {}
      const result = interpretLine(decode(last)).result
      if (entry.journal.cancelled === turns) {
        this.finish(entry, 'cancelled', 'Cancelled.', false)
      } else if (result && result.turn === turns) {
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
      if (entry.journalError) {
        entry.task.status = 'running'; this.finish(entry, 'failed', entry.journalError, false)
      } else {
        try {
          if (entry.journal.intent?.legacy && result?.turn === turns) {
            let legacyEvent: any
            try { legacyEvent = JSON.parse(decode(last)) } catch { /* Invalid lines are not terminal evidence. */ }
            if (legacyEvent?.type === 'turn_failed') await this.uncertain(entry)
            else await this.retireIntent(entry)
          } else await this.recoverDelivery(entry)
        } catch (error) {
          entry.journalError = `Cannot reconcile durable delivery: ${error instanceof Error ? error.message : 'guest read failed'}`
          entry.task.status = 'running'; this.finish(entry, 'failed', entry.journalError, false)
        }
        this.syncQueue(entry, false)
        // Resume only proven unclaimed work or replies after a proven completed turn.
        if (!entry.journalError && !isLive(entry.task.status) && !entry.task.delivery && entry.queue.length && entry.task.status === 'succeeded') {
          await this.serial(entry, () => this.continueQueue(entry, entry.task.status))
        }
      }
    }
  }

  private restored = false
  private needsRecovery = false
  private recovering?: Promise<void>

  /** Stops tailing (the computer is parking); running tasks resume being tailed on wake. */
  pause(): void {
    this.eventGeneration++
    if (this.timer) this.timer()
    this.timer = undefined
    this.eventsChanged?.()
  }

  /** After pause, wait for any mailbox guest command and admitted dispatch to settle. */
  async drainToolWork(): Promise<void> { await this.toolWork }

  resume(): void {
    if (this.needsRecovery && !this.recovering) {
      this.needsRecovery = false
      const release = this.acquire()
      this.recovering = Promise.all([...this.tracked.values()].map(entry => this.serial(entry, () => this.recoverDelivery(entry))))
        .then(() => { if ([...this.tracked.values()].some(entry => isLive(entry.task.status))) this.ensurePolling() })
        .catch(error => { this.needsRecovery = true; console.error('Agent recovery failed:', error) })
        .finally(() => { this.recovering = undefined; release() })
    }
    if (!this.restored) void this.restore().catch(error => console.error('Agent recovery failed:', error))
    if ([...this.tracked.values()].some(entry => isLive(entry.task.status))) this.ensurePolling()
  }

  /** Only host-tracked live tasks are eligible for guest watches. */
  eventTasks(): Array<{ id: string; offset: number; turn: number }> {
    return [...this.tracked.values()].filter(entry => !entry.deleting && isLive(entry.task.status))
      .map(entry => ({ id: entry.task.id, offset: entry.offset, turn: entry.task.turns }))
  }

  private ensurePolling(): void {
    if (!this.timer) {
      const tick = this.subscribe?.('agent.tick', record => this.acceptTick(record))
      const mailbox = this.subscribe?.('agent.mailbox', record => this.acceptMailbox(record))
      this.timer = () => { tick?.(); mailbox?.() }
    }
    this.eventsChanged?.()
  }

  async acceptTick(raw: unknown): Promise<void> {
    if (!raw || typeof raw !== 'object' || Array.isArray(raw)) return
    const value = raw as Record<string, unknown>
    if (typeof value.id !== 'string' || !TASK_ID.test(value.id) || typeof value.output !== 'string'
      || Buffer.byteLength(value.output) > 1048576 || !Number.isSafeInteger(value.offset) || (value.offset as number) < 0
      || !Number.isSafeInteger(value.nextOffset) || (value.nextOffset as number) < 0
      || !Number.isSafeInteger(value.chunk) || (value.chunk as number) < 1 || (value.chunk as number) > POLL_BUDGET) return
    const entry = this.tracked.get(value.id)
    if (!entry || entry.deleting || !isLive(entry.task.status)) return
    const digest = createHash('sha256').update(JSON.stringify(value)).digest('hex')
    if (entry.lastEventDigest === digest) return
    const report = parsePoll(value.output).get(value.id)
    if (!report || report.data.length > (value.chunk as number)) return
    const offset = value.reset === true ? 0 : entry.offset
    if (value.offset !== offset || value.nextOffset !== offset + report.data.length) return
    if (value.reset === true) { entry.offset = 0; entry.carry = Buffer.alloc(0); entry.discardLine = false }
    const previous = { offset: entry.offset, carry: entry.carry, discardLine: entry.discardLine, turn: entry.turn }
    try { this.apply(entry, report, value.chunk as number) }
    catch (error) { Object.assign(entry, previous); throw error }
    entry.lastEventDigest = digest
    if (!entry.replying) await entry.replyChain
  }

  async acceptMailbox(raw: unknown): Promise<void> {
    const work = this.consumeMailbox(raw)
    this.toolWork = work
    try { await work } finally { if (this.toolWork === work) this.toolWork = undefined }
  }

  private async consumeMailbox(raw: unknown): Promise<void> {
    if (!raw || typeof raw !== 'object' || Array.isArray(raw) || !this.toolJournal || !this.timer) return
    const value = raw as Record<string, unknown>
    if (typeof value.id !== 'string' || !TASK_ID.test(value.id) || typeof value.request !== 'string'
      || value.request.length > 90000 || !/^[A-Za-z0-9+/]*={0,2}$/.test(value.request)) return
    const guest = this.guest()
    if (!guest) throw new AgentUnavailableError()
    const generation = this.eventGeneration
    const journal = await this.toolJournal()
    if (!journal || generation !== this.eventGeneration) return
    const entry = this.tracked.get(value.id)
    if (!entry?.task.profileId || entry.deleting || entry.task.status !== 'running') return
    let request: unknown
    try { request = JSON.parse(Buffer.from(value.request, 'base64').toString('utf8')) } catch { return }
    if (!request || typeof request !== 'object' || !('id' in request)) return
    const task = { id: entry.task.id, profileId: entry.task.profileId, turn: entry.task.turns }
    await acceptAgentTools(guest, journal, [task], current => generation === this.eventGeneration && !!this.timer
      && this.tracked.get(current.id) === entry && !entry.deleting && entry.task.status === 'running'
      && entry.task.turns === current.turn && entry.task.profileId === current.profileId,
      [[task.id, request.id, value.request]])
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
      const versions = new Map(live.map(entry => [entry.task.id, { turn: entry.task.turns, offset: entry.offset }]))
      const chunk = Math.max(MIN_TASK_CHUNK, Math.floor(POLL_BUDGET / live.length))
      const output = await guest.run('/bin/sh', ['-c', POLL_SCRIPT, 'sh', String(chunk),
        ...live.flatMap(entry => [`${HOME}/Agents/${entry.task.id}`, String(entry.offset)])], 20_000).catch(() => undefined)
      if (output === undefined) return
      const reports = parsePoll(output)
      for (const entry of live) {
        const report = reports.get(entry.task.id)
        const version = versions.get(entry.task.id)!
        if (report && !entry.deleting && this.tracked.get(entry.task.id) === entry && isLive(entry.task.status) && entry.task.turns === version.turn && entry.offset === version.offset) this.apply(entry, report, chunk)
        if (!entry.replying) await entry.replyChain
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
    let began = false
    for (let end = buffer.indexOf(10); end >= 0; start = end + 1, end = buffer.indexOf(10, start)) {
      if (entry.discardLine || end - start > 2097152) { entry.discardLine = false; continue }
      const line = buffer.subarray(start, end).toString('utf8')
      if (!line.trim()) continue
      try {
        const state = JSON.parse(line)
        if (state.type === 'models') {
          entry.task.models = publicModels(state.models)
          entry.task.requestedModel = typeof state.requestedModel === 'string' ? modelId(state.requestedModel) : undefined
        }
      } catch {}
      const interpreted = interpretLine(line)
      if (interpreted.turn !== undefined) {
        entry.turn = interpreted.turn
        if (entry.turn === entry.task.turns) began = true
      }
      if (entry.turn === entry.task.turns) {
        for (const output of interpreted.outputs) this.emit({ type: 'agent.task.output', id, ...output })
        const transcript = transcriptEntry(line)
        if (transcript) this.emit({ type: 'agent.task.event', id, turn: entry.turn, entry: transcript })
      }
      if (interpreted.result?.turn === entry.task.turns) result ??= interpreted.result
    }
    if (entry.discardLine || buffer.length - start > 2097152) { entry.carry = Buffer.alloc(0); entry.discardLine = true }
    else entry.carry = Buffer.from(buffer.subarray(start))
    // Ignore snapshots from an older turn or beyond the transcript bytes consumed this tick.
    const draft = report.draft
    this.setDraft(entry, !result && report.data.length < chunk && draft?.turn === entry.task.turns
      && draft.after === entry.offset ? { turn: draft.turn, kind: draft.kind, text: draft.text } : null)
    if (result) return this.finishWith(entry, result)
    if (began && entry.journal.intent?.replies.length && !entry.journal.intent.claimed) {
      void this.serial(entry, () => this.recoverDelivery(entry, false, true)).catch(error => console.error('Cannot confirm turn claim:', error))
    }
    this.updatePending(entry, report.requests)
    // A full chunk means more transcript is waiting; finish only once it has all been read.
    if (report.exitCode === '' || report.data.length >= chunk) return
    const stderr = report.stderr.trim()
    this.finish(entry, 'failed', stderr || `The agent runner exited with code ${report.exitCode} before the turn ended.`, false)
    void this.serial(entry, async () => {
      await this.recoverDelivery(entry, false)
      this.announceFinished(entry)
    }).catch(error => console.error('Delivery recovery failed:', error))
  }

  private finishWith(entry: Tracked, result: TurnResult, announce = true, keepLease = false): void {
    entry.completedTurn = result.turn
    if (result.uncertain && entry.journal.intent) {
      entry.task.delivery = { turn: result.turn, state: 'uncertain', message: result.summary.slice(0, 2000) }
      this.finish(entry, 'failed', result.summary, announce, undefined, false, result.finishedAt)
      if (announce) void this.serial(entry, () => this.uncertain(entry)).catch(error => console.error('Cannot persist uncertain delivery:', error))
      return
    }
    if (result.signIn) {
      const name = entry.task.agentName ?? entry.task.agent
      return this.finish(entry, 'failed', `Sign in to ${name} first.`, announce, result.signIn, false, result.finishedAt)
    }
    this.finish(entry, result.status, result.summary, announce, undefined, keepLease, result.finishedAt)
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

  private setDraft(entry: Tracked, draft: AgentDraft | null): void {
    if (JSON.stringify(entry.task.draft ?? null) === JSON.stringify(draft)) return
    if (draft) entry.task.draft = draft
    else delete entry.task.draft
    this.emit({ type: 'agent.task.draft', id: entry.task.id, draft })
  }

  private syncQueue(entry: Tracked, announce = true): void {
    const before = JSON.stringify([entry.task.queued ?? [], entry.task.queuedAttachments ?? []])
    const visible = entry.queue.filter(reply => entry.task.delivery || entry.journal.intent?.turn !== entry.task.turns || !entry.journal.intent.replies.includes(reply.id))
    const queued = visible.map(reply => reply.prompt)
    const files = visible.map(reply => reply.attachments.map(file => file.path))
    if (queued.length) entry.task.queued = queued
    else delete entry.task.queued
    if (files.some(paths => paths.length)) entry.task.queuedAttachments = files
    else delete entry.task.queuedAttachments
    if (announce && before !== JSON.stringify([entry.task.queued ?? [], entry.task.queuedAttachments ?? []])) this.emit({ type: 'agent.task.queued', id: entry.task.id, queued,
      ...(entry.task.queuedAttachments ? { queuedAttachments: files } : {}) })
  }

  private syncPending(entry: Tracked): void {
    const first = entry.pending[0]
    if (first) entry.task.pendingApproval = { id: first.id, tool: first.tool, summary: first.summary, ...(first.options ? { options: first.options } : {}) }
    else delete entry.task.pendingApproval
  }

  private finish(entry: Tracked, status: TaskStatus, summary: string, announce = true, signIn?: SignInMethod[], keepLease = false, finishedAt?: string): void {
    if (!isLive(entry.task.status)) return
    this.setDraft(entry, null)
    entry.task.status = status
    this.eventsChanged?.()
    // Restoring old history is not a new completion. Legacy records without a
    // durable timestamp stay undated rather than resurfacing after every restart.
    entry.task.finishedAt = finishedAt ?? (announce ? new Date().toISOString() : undefined)
    entry.task.summary = summary.slice(0, 2000)
    if (signIn) entry.task.signIn = signIn
    entry.pending = []
    delete entry.task.pendingApproval
    // A claimed Send Now transition owns the lease and the next delivery, even if polling
    // observes a normal turn_end while cancellation is still in flight.
    if (announce && entry.replying) return
    // Replies waited for this turn: they go to the agent now, as one turn, under the same lease.
    if (announce && entry.completedTurn === entry.task.turns && (entry.queue.length || entry.journal.intent) && status !== 'cancelled' && !signIn && !entry.task.delivery) {
      void this.serial(entry, () => this.continueQueue(entry, status))
      return
    }
    if (!keepLease) {
      this.releases.get(entry.task.id)?.()
      this.releases.delete(entry.task.id)
    }
    if (announce) this.announceFinished(entry)
  }

  private async continueQueue(entry: Tracked, status: TaskStatus): Promise<void> {
    try {
      await this.recoverDelivery(entry)
      if (!entry.task.delivery && entry.queue.length) await this.sendTurn(entry)
      else {
        this.releases.get(entry.task.id)?.(); this.releases.delete(entry.task.id)
        this.announceFinished(entry)
      }
    } catch (error) {
      // The queue stays, to go with the owner's next reply.
      console.error('Queued reply was not delivered:', error)
      if (entry.task.status === status) {
        this.releases.get(entry.task.id)?.()
        this.releases.delete(entry.task.id)
        this.announceFinished(entry)
      }
    }
  }

  private announceFinished(entry: Tracked): void {
    const { id, status, summary = '', signIn } = entry.task
    this.emit({ type: 'agent.task.finished', id, status, summary, ...(signIn ? { signIn } : {}) })
  }
}

function isLive(status: TaskStatus): boolean { return status === 'running' || status === 'paused' }

function readPrompt(value: unknown): string {
  const prompt = typeof value === 'string' ? value.trim() : ''
  if (!prompt || prompt.length > MAX_PROMPT || prompt.includes('\0')) throw new AgentInputError('prompt must be 1–32000 characters')
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

interface PollReport { draft?: AgentDraft & { after: number }; exitCode: string; stderr: string; data: Buffer; requests: Array<{ id: string; json: string }> }

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
  '  p=$(cat "$d/pid" 2>/dev/null || true); if [ -z "$e" ] && { [ -z "$p" ] || ! kill -0 "$p" 2>/dev/null; }; then e=interrupted; fi',
  '  [ -n "$e" ] && err=$(tail -c 400 "$d/stderr.log" 2>/dev/null | base64 -w0)',
  "  printf 'T\\t%s\\t%s\\t%s\\t' \"$id\" \"$e\" \"$err\"",
  '  tail -c +"$((o + 1))" "$d/transcript.jsonl" 2>/dev/null | head -c "$max" | base64 -w0',
  "  printf '\\n'",
  `  printf 'D\\t%s\\t%s\\n' "$id" "$(head -c 131072 "$d/draft.json" 2>/dev/null | base64 -w0)"`,
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
    } else if (fields[0] === 'D' && fields[1]) {
      const report = reports.get(fields[1])
      try {
        const value = JSON.parse(decode(fields[2]))
        if (report && Number.isSafeInteger(value.turn) && value.turn > 0 && Number.isSafeInteger(value.after) && value.after >= 0
            && (value.kind === 'text' || value.kind === 'thought') && typeof value.text === 'string' && value.text.length <= 16_000) {
          report.draft = { turn: value.turn, after: value.after, kind: value.kind, text: value.text }
        }
      } catch { /* A missing, partial or malformed guest snapshot is not a draft. */ }
    } else if (fields[0] === 'A' && fields[1] && fields[2] && REQUEST_ID.test(fields[2])) {
      reports.get(fields[1])?.requests.push({ id: fields[2], json: decode(fields[3]) })
    }
  }
  return reports
}

/** Prints the transcript's size, a tab, and its last $2 bytes in base64; "0\t" when there is none. */
const TRANSCRIPT_SCRIPT = [
  '[ -f "$1" ] || { printf "0\\t"; exit 0; }',
  'printf "%s\\t" "$(stat -c %s "$1")"',
  'tail -c "$2" "$1" | base64 -w0',
].join('\n')

/**
 * One tab-separated line per task directory (or the requested $2 id): id, agent id, start time, the
 * runner's exit code, whether it is alive, transcript size, base64 prompt, base64 last line
 * that ends a turn, approval mode, turns, whether task.json exists (1 or 0), base64
 * attachment names, base64 agent name, optional profile UUID.
 */
const RESTORE_SCRIPT = [
  'cd "$1" 2>/dev/null || exit 0',
  'for d in ${2:-$(ls -1t)}; do',
  '  [ ! -e ".deleted-$d" ] || continue',
  '  [ -f "$d/prompt.txt" ] || continue',
  '  pid=$(cat "$d/pid" 2>/dev/null); alive=0; [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null && alive=1',
  '  resumable=0; [ -f "$d/task.json" ] && resumable=1',
  `  last=$(tail -c 2097152 "$d/transcript.jsonl" 2>/dev/null | grep -E '"type":"(turn_end|turn_failed|auth_required)"' | tail -n 1 | head -c 131072)`,
  '  printf "%s\\t%s\\t%s\\t%s\\t%s\\t%s\\t%s\\t%s\\t%s\\t%s\\t%s\\t%s\\t%s\\t%s\\n" "$d" "$(head -c 64 "$d/agent" 2>/dev/null)" "$(stat -c %Y "$d/prompt.txt")" \\',
  '    "$(cat "$d/exit-code" 2>/dev/null)" "$alive" "$(stat -c %s "$d/transcript.jsonl" 2>/dev/null || echo 0)" \\',
  '    "$(head -c 128000 "$d/prompt.txt" | base64 -w0)" "$(printf %s "$last" | base64 -w0)" \\',
  '    "$(head -c 8 "$d/approval-mode" 2>/dev/null || echo auto)" "$(head -c 8 "$d/turns" 2>/dev/null || echo 1)" "$resumable" \\',
  '    "$(ls -1 "$d/attachments" 2>/dev/null | head -c 4096 | base64 -w0)" "$(head -c 400 "$d/agent-name" 2>/dev/null | base64 -w0)" "$(head -c 36 "$d/profile-id" 2>/dev/null)"',
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

/** Fixed field order; compare original request fields and file contents, never mutable launch defaults. */
function fingerprint(input: Record<string, unknown>, files: ReturnType<typeof readAttachments>, start = false, profile?: AgentProfileSnapshot): string {
  return createHash('sha256').update(JSON.stringify({ prompt: input.prompt,
    ...(start ? { agent: input.agent ?? null, approvals: input.approvals ?? null, craftMcp: input.craftMcp ?? null, ...(input.model !== undefined ? { model: modelId(input.model) } : {}) } : {}),
    ...(profile ? { profile } : {}),
    attachments: files.map((file, index) => ({ name: (input.attachments as any[])[index].name,
      type: (input.attachments as any[])[index].type ?? null, sha256: createHash('sha256').update(file.data).digest('hex') })) })).digest('hex')
}
