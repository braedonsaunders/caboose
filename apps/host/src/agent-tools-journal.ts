import { createHash, randomUUID } from 'node:crypto'
import { mkdir, open, readFile, rename, unlink } from 'node:fs/promises'
import { dirname } from 'node:path'

/** The caller supplies identity from a live, host-tracked task, never from guest input. */
export interface ToolScope { taskId: string; profileId: string; turn: number }
export interface ToolRequest { id: string; tool: string; arguments: Record<string, unknown> }
export type ToolResult = { ok: true; value: unknown } | { ok: false; error: string }
export type ToolDispatcher = (scope: ToolScope, tool: string, args: Record<string, unknown>) => Promise<unknown>
const uuid = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/
const tools = new Set(['profile_read', 'memory_list', 'memory_remember', 'memory_update', 'memory_forget', 'routine_list', 'routine_get', 'routine_create', 'routine_update', 'routine_pause', 'routine_delete', 'routine_run', 'routine_history'])
const reads = new Set(['profile_read', 'memory_list', 'routine_list', 'routine_get', 'routine_history'])
const MAX_REQUEST = 64 * 1024
const MAX_RESULT = 128 * 1024
const MAX_RECORDS = 256
const MAX_TOTAL = 2000
const MAX_STATE = 32 * 1024 * 1024
/** Throw only when validation failed before any mutation. */
export class ToolValidationError extends Error {}
interface Receipt { id: string; taskId: string; profileId: string; turn: number; hash: string; result?: ToolResult }
interface State { version: 1; receipts: Receipt[]; bindings?: Record<string, string> }

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
    if (state.bindings !== undefined && (!state.bindings || typeof state.bindings !== 'object' || Array.isArray(state.bindings) || Object.entries(state.bindings).length > MAX_TOTAL || Object.entries(state.bindings).some(([task, profile]) => !uuid.test(task) || typeof profile !== 'string' || !uuid.test(profile)))) throw new Error('Invalid tool task bindings')
    const keys = new Set<string>()
    for (const receipt of state.receipts) {
      const key = `${receipt.taskId}:${receipt.id}`
      if (keys.has(key)) throw new Error('Duplicate tool receipt')
      keys.add(key)
      if (receipt.result !== undefined && (!receipt.result || typeof receipt.result !== 'object' || (receipt.result.ok !== true && receipt.result.ok !== false) || (receipt.result.ok === false && (typeof receipt.result.error !== 'string' || receipt.result.error.length > 2000)) || Buffer.byteLength(JSON.stringify(receipt.result)) > MAX_RESULT + 4096)) throw new Error('Invalid tool receipt result')
    }
    if (state.receipts.length > MAX_TOTAL || Buffer.byteLength(JSON.stringify(state)) > MAX_STATE) throw new Error('Tool journal capacity exceeded')
    return new AgentToolJournal(path, state, dispatch)
  }

  profileForTask(taskId: string): string | undefined { return this.state.bindings?.[taskId] }

  bindTask(taskId: string, profileId: string): Promise<void> {
    const operation = this.chain.then(async () => {
      if (this.failed) throw new Error('Tool journal persistence failed; reopen before continuing')
      if (!uuid.test(taskId) || !uuid.test(profileId)) throw new Error('Invalid tool task binding')
      const existing = this.profileForTask(taskId)
      if (existing && existing !== profileId) throw new Error('Tool task binding conflicts')
      if (existing) return
      const bindings = { ...this.state.bindings, [taskId]: profileId }
      if (Object.keys(bindings).length > MAX_TOTAL || Buffer.byteLength(JSON.stringify(this.state)) + 256 > MAX_STATE) throw new Error('Tool journal capacity reached')
      await this.persist({ ...this.state, bindings })
    })
    this.chain = operation.catch(() => {})
    return operation
  }

  execute(scope: ToolScope, request: ToolRequest, allowed: () => boolean = () => true): Promise<ToolResult> {
    const operation = this.chain.then(() => this.perform(scope, request, allowed))
    this.chain = operation.catch(() => {})
    return operation
  }

  private async persist(state: State): Promise<void> {
    const temp = `${this.path}.${randomUUID()}.tmp`
    try {
      await mkdir(dirname(this.path), { recursive: true })
      const file = await open(temp, 'wx', 0o600)
      try { await file.writeFile(JSON.stringify(state)); await file.sync() } finally { await file.close() }
      await rename(temp, this.path)
      const dir = await open(dirname(this.path), 'r')
      try { await dir.sync() } finally { await dir.close() }
    } catch (error) { this.failed = true; throw error }
    finally { await unlink(temp).catch(() => {}) }
    this.state = state
  }

  private async perform(scope: ToolScope, request: ToolRequest, allowed: () => boolean): Promise<ToolResult> {
    if (this.failed) throw new Error('Tool journal persistence failed; reopen before continuing')
    if (!allowed()) throw new Error('Agent turn is no longer active')
    if (!uuid.test(scope.taskId) || !uuid.test(scope.profileId) || !Number.isSafeInteger(scope.turn) || scope.turn < 1 || !request || !uuid.test(request.id) || !tools.has(request.tool) || !request.arguments || typeof request.arguments !== 'object' || Array.isArray(request.arguments)) throw new Error('Invalid tool request or task scope')
    if (this.profileForTask(scope.taskId) !== scope.profileId) throw new Error('Task has no matching host tool binding')
    const payload = JSON.stringify({ tool: request.tool, arguments: request.arguments })
    if (Buffer.byteLength(payload) > MAX_REQUEST) throw new Error('Tool request too large')
    const hash = createHash('sha256').update(payload).digest('hex')
    const previous = this.state.receipts.find(r => r.taskId === scope.taskId && r.id === request.id)
    if (previous) {
      if (previous.hash !== hash || previous.profileId !== scope.profileId || previous.turn !== scope.turn) throw new Error('Tool request id conflicts with an earlier request')
      return previous.result ? structuredClone(previous.result) : { ok: false, error: 'The previous operation may have completed. Inspect memory or routines before deciding what to do; it will not be repeated.' }
    }
    if (this.state.receipts.filter(r => r.taskId === scope.taskId).length >= MAX_RECORDS) throw new Error('Task tool receipt limit reached; start a new task')
    if (this.state.receipts.length >= MAX_TOTAL || Buffer.byteLength(JSON.stringify(this.state)) + MAX_RESULT + 4096 > MAX_STATE) throw new Error('Tool journal capacity reached')
    // Read operations have no effects, but are journaled too so duplicate IDs remain consistent.
    const receipt: Receipt = { id: request.id, ...scope, hash }
    await this.persist({ ...this.state, receipts: [...this.state.receipts, receipt] })
    let result: ToolResult
    try {
      if (!allowed()) throw new ToolValidationError('Agent turn is no longer active')
      const value = await this.dispatch(scope, request.tool, request.arguments)
      const encoded = JSON.stringify(value ?? null)
      result = Buffer.byteLength(encoded) <= MAX_RESULT ? { ok: true, value: value ?? null } : { ok: false, error: reads.has(request.tool) ? 'Tool result too large' : 'Operation completed but its result was too large; inspect current state.' }
    } catch (error) {
      result = { ok: false, error: reads.has(request.tool) || error instanceof ToolValidationError ? String(error).slice(0, 2000) : 'Operation failed or its outcome is uncertain. Inspect current state before retrying.' }
    }
    await this.persist({ ...this.state, receipts: this.state.receipts.map(r => r === receipt ? { ...r, result } : r) })
    return structuredClone(result)
  }
}
