import { AgentConflictError, AgentInputError, AgentNotFoundError } from './agents.js'
import type { AgentProfiles } from './agent-profiles.js'
import type { AgentRoutines } from './agent-routines.js'
import { ToolValidationError, type ToolDispatcher } from './agent-tools-journal.js'

function keys(input: Record<string, unknown>, allowed: string[]): void {
  for (const key of Object.keys(input)) if (!allowed.includes(key)) throw new ToolValidationError(`Unknown argument: ${key}`)
}
function identifier(value: unknown): string {
  if (typeof value !== 'string' || !/^[0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12}$/.test(value)) throw new ToolValidationError('A canonical UUID is required')
  return value
}
function page(value: unknown, fallback: number, min: number, max: number): number {
  if (value === undefined) return fallback
  if (typeof value !== 'number' || !Number.isSafeInteger(value) || value < min || value > max) throw new ToolValidationError(`Expected an integer from ${min} to ${max}`)
  return value
}
const routineFields = ['name', 'prompt', 'schedule', 'paused', 'missed', 'overlap', 'deliveryGraceMs']

/** Domain permissions come from the tracked task, never from guest arguments or a host token. */
export function agentAutomation(profiles: AgentProfiles, getRoutines: () => Promise<AgentRoutines | null>, changed: () => void): ToolDispatcher {
  return async (scope, tool, args) => {
    // Validate before mutating. Failures after a durable write remain uncertain to the journal.
    const profile = profiles.get(scope.profileId)
    const mutation = !['profile_read', 'memory_list', 'routine_list', 'routine_get', 'routine_history'].includes(tool)
    if (mutation && profile.archived) throw new ToolValidationError('This profile is archived; ask the owner to restore it')
    if (tool === 'profile_read') { keys(args, []); const { memories: _memories, ...identity } = profile; return identity }
    if (tool === 'memory_list') {
      keys(args, ['offset', 'limit']); const offset = page(args.offset, 0, 0, 100), limit = page(args.limit, 20, 1, 20)
      return { memories: profile.memories.slice(offset, offset + limit), total: profile.memories.length }
    }
    const routines = await getRoutines()
    if (!routines) throw new ToolValidationError('Routine service is unavailable')
    const ownRoutine = (value: unknown) => {
      const routine = routines.get(identifier(value))
      if (routine.profileId !== scope.profileId) throw new ToolValidationError('Routine does not belong to this profile')
      return routine
    }
    let committed = false
    try {
      if (tool === 'memory_remember' || tool === 'memory_update' || tool === 'memory_forget') {
        if (tool === 'memory_remember') keys(args, ['title', 'content'])
        else if (tool === 'memory_update') keys(args, ['id', 'title', 'content'])
        else keys(args, ['id'])
        const memoryId = tool === 'memory_remember' ? undefined : identifier(args.id)
        const { id: _id, ...patch } = args
        const previous = memoryId ? profile.memories.find(memory => memory.id === memoryId) : undefined
        const input = tool === 'memory_update' && previous ? { title: previous.title, content: previous.content, ...patch } : patch
        const updated = tool === 'memory_forget' ? await profiles.forget(profile.id, memoryId!) : await profiles.remember(profile.id, input, memoryId)
        committed = true
        await routines.profileChanged(profile.id); changed()
        return tool === 'memory_forget' ? { deleted: true } : { id: memoryId ?? updated.memories.at(-1)!.id }
      }
      if (tool === 'routine_list') {
        keys(args, [])
        return { routines: routines.list().filter(r => r.profileId === profile.id).map(({ id, name, schedule, nextAt, paused }) => ({ id, name, schedule, nextAt, paused })) }
      }
      if (tool === 'routine_get') { keys(args, ['id']); return { routine: ownRoutine(args.id) } }
      if (tool === 'routine_create') {
        keys(args, routineFields)
        const routine = await routines.create({ ...args, profileId: profile.id })
        return { id: routine.id, nextAt: routine.nextAt }
      }
      if (tool === 'routine_update') {
        keys(args, ['id', 'patch']); const routine = ownRoutine(args.id)
        if (!args.patch || typeof args.patch !== 'object' || Array.isArray(args.patch)) throw new ToolValidationError('patch must be an object')
        keys(args.patch as Record<string, unknown>, routineFields)
        const updated = await routines.update(routine.id, args.patch)
        return { id: updated.id, nextAt: updated.nextAt, paused: updated.paused }
      }
      if (tool === 'routine_pause') {
        keys(args, ['id', 'paused']); const routine = ownRoutine(args.id)
        if (typeof args.paused !== 'boolean') throw new ToolValidationError('paused must be a boolean')
        await routines.update(routine.id, { paused: args.paused }); return { id: routine.id, paused: args.paused }
      }
      if (tool === 'routine_delete') { keys(args, ['id']); await routines.delete(ownRoutine(args.id).id); return { deleted: true } }
      if (tool === 'routine_run') { keys(args, ['id']); const run = await routines.runNow(ownRoutine(args.id).id); return { id: run.id, status: run.status } }
      if (tool === 'routine_history') {
        keys(args, ['id', 'limit']); const limit = page(args.limit, 20, 1, 20)
        const id = args.id === undefined ? undefined : identifier(args.id)
        return { runs: routines.history(id).filter(run => run.profileId === profile.id).slice(0, limit) }
      }
      throw new ToolValidationError('Unknown persistent agent tool')
    } catch (error) {
      if (!committed && (error instanceof AgentInputError || error instanceof AgentConflictError || error instanceof AgentNotFoundError)) throw new ToolValidationError(error.message)
      throw error
    }
  }
}
