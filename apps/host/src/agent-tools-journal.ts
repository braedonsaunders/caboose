import { createHash, randomUUID } from 'node:crypto'
import { mkdir, open, readFile, rename, unlink } from 'node:fs/promises'
import { dirname } from 'node:path'

/** The caller supplies identity from a live, host-tracked task, never from guest input. */
export interface ToolScope { taskId: string; profileId: string; turn: number }
export interface ToolRequest { id: string; tool: string; arguments: Record<string, unknown> }
export type ToolResult = { ok: true; value: unknown } | { ok: false; error: string }
export type ToolDispatcher = (scope: ToolScope, tool: string, args: Record<string, unknown>) => Promise<unknown>
const uuid = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/
const tools = new Set(['profile_read', 'memory_list', 'memory_remember', 'memory_update', 'memory_forget', 'routine_list', 'routine_create', 'routine_update', 'routine_pause', 'routine_delete', 'routine_run', 'routine_history'])
const reads = new Set(['profile_read', 'memory_list', 'routine_list', 'routine_history'])
const MAX_REQUEST = 64 * 1024
const MAX_RESULT = 128 * 1024
const MAX_RECORDS = 256
interface Receipt { id: string; taskId: string; profileId: string; turn: number; hash: string; result?: ToolResult }
interface State { version: 1; receipts: Receipt[] }

/** Single host process per path. A pending write-ahead receipt is deliberately never replayed. */
export class AgentToolJournal {
  private chain: Promise<unknown> = Promise.resolve()
  private failed = false
  private readonly path: string
  private state: State
  private readonly dispatch: ToolDispatcher
  private constructor(path: string, state: State, dispatch: ToolDispatcher) { this.path = path; this.state = state; this.dispatch = dispatch }

  static async open(path: string, dispatch: ToolDispatcher): Promise<AgentToolJournal> {
    let state: State = { version: 1, receipts: [] }
    try {
      const file = await open(path, 'r')
      try {
        const stat = await file.stat()
        if (!stat.isFile() || stat.size > 40 * 1024 * 1024) throw new Error('Invalid tool journal size')
        state = JSON.parse(await file.readFile('utf8')) as State
      } finally { await file.close() }
    } catch (error) { if ((error as NodeJS.ErrnoException).code !== 'ENOENT') throw error }
    if (!state || state.version !== 1 || !Array.isArray(state.receipts) || state.receipts.length > 100_000 || state.receipts.some(r => !r || !uuid.test(r.id) || !uuid.test(r.taskId) || !uuid.test(r.profileId) || !Number.isSafeInteger(r.turn) || r.turn < 1 || !/^[0-9a-f]{64}$/.test(r.hash))) throw new Error('Invalid tool journal')
    return new AgentToolJournal(path, state, dispatch)
  }

  execute(scope: ToolScope, request: ToolRequest): Promise<ToolResult> {
    const operation = this.chain.then(() => this.perform(scope, request))
    this.chain = operation.catch(() => {})
    return operation
  }

  private async persist(state: State): Promise<void> {
    await mkdir(dirname(this.path), { recursive: true })
    const temp = `${this.path}.${randomUUID()}.tmp`
    try {
      const file = await open(temp, 'wx', 0o600)
      try { await file.writeFile(JSON.stringify(state)); await file.sync() } finally { await file.close() }
      await rename(temp, this.path)
      const dir = await open(dirname(this.path), 'r')
      try { await dir.sync() } finally { await dir.close() }
    } catch (error) { this.failed = true; throw error }
    finally { await unlink(temp).catch(() => {}) }
    this.state = state
  }

  private async perform(scope: ToolScope, request: ToolRequest): Promise<ToolResult> {
    if (this.failed) throw new Error('Tool journal persistence failed; reopen before continuing')
    if (!uuid.test(scope.taskId) || !uuid.test(scope.profileId) || !Number.isSafeInteger(scope.turn) || scope.turn < 1 || !request || !uuid.test(request.id) || !tools.has(request.tool) || !request.arguments || typeof request.arguments !== 'object' || Array.isArray(request.arguments)) throw new Error('Invalid tool request or task scope')
    const payload = JSON.stringify({ tool: request.tool, arguments: request.arguments })
    if (Buffer.byteLength(payload) > MAX_REQUEST) throw new Error('Tool request too large')
    const hash = createHash('sha256').update(payload).digest('hex')
    const previous = this.state.receipts.find(r => r.taskId === scope.taskId && r.id === request.id)
    if (previous) {
      if (previous.hash !== hash || previous.profileId !== scope.profileId || previous.turn !== scope.turn) throw new Error('Tool request id conflicts with an earlier request')
      return previous.result ?? { ok: false, error: 'The previous operation may have completed. Inspect memory or routines before deciding what to do; it will not be repeated.' }
    }
    if (this.state.receipts.filter(r => r.taskId === scope.taskId).length >= MAX_RECORDS) throw new Error('Task tool receipt limit reached; start a new task')
    // Read operations have no effects, but are journaled too so duplicate IDs remain consistent.
    const receipt: Receipt = { id: request.id, ...scope, hash }
    await this.persist({ version: 1, receipts: [...this.state.receipts, receipt] })
    let result: ToolResult
    try {
      const value = await this.dispatch(scope, request.tool, request.arguments)
      const encoded = JSON.stringify(value ?? null)
      result = Buffer.byteLength(encoded) <= MAX_RESULT ? { ok: true, value: value ?? null } : { ok: false, error: reads.has(request.tool) ? 'Tool result too large' : 'Operation completed but its result was too large; inspect current state.' }
    } catch (error) {
      result = { ok: false, error: reads.has(request.tool) ? String(error).slice(0, 2000) : 'Operation failed or its outcome is uncertain. Inspect current state before retrying.' }
    }
    await this.persist({ version: 1, receipts: this.state.receipts.map(r => r === receipt ? { ...r, result } : r) })
    return result
  }
}
