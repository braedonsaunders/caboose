import { expect, it } from 'vitest'
import { AgentProfiles } from './agent-profiles.js'
import { AgentRoutines, type RoutineState } from './agent-routines.js'
import { agentAutomation } from './agent-automation.js'

it('scopes memory and routine tools to the bound profile and keeps deleted-run history scoped', async () => {
  const profiles = new AgentProfiles({ version: 1, profiles: [] }, { save: async () => {} })
  const mine = await profiles.create({ name: 'Mine', agent: 'claude-acp' })
  const other = await profiles.create({ name: 'Other', agent: 'claude-acp' })
  let stored: RoutineState | undefined
  const routines = await AgentRoutines.create({ load: async () => stored, save: async state => { stored = structuredClone(state) } }, {
    runtime: { snapshot: async (id, prompt) => ({ revision: id, input: { prompt } }), acquire: async () => () => {}, lookup: async () => null, start: async () => ({ status: 'succeeded' }) },
  })
  const dispatch = agentAutomation(profiles, async () => routines, () => {})
  const scope = { taskId: 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee', profileId: mine.id, turn: 1 }
  const run = (tool: string, args: Record<string, unknown> = {}) => dispatch(scope, tool, args)
  try {
    await expect(run('profile_read', { profileId: other.id })).rejects.toThrow('Unknown argument')
    const saved = await run('memory_remember', { title: 'Timezone', content: 'America/Toronto' }) as { id: string }
    await run('memory_update', { id: saved.id, content: 'America/Vancouver' })
    expect(profiles.get(mine.id).memories).toMatchObject([{ title: 'Timezone', content: 'America/Vancouver' }])
    expect(profiles.get(other.id).memories).toEqual([])
    await expect(run('memory_list', { limit: 999 })).rejects.toThrow()
    const definition = { name: 'Report', profileId: other.id, prompt: 'Summarize', schedule: { kind: 'daily', timeZone: 'UTC', time: '09:00' } }
    const theirs = await routines.create(definition)
    await expect(run('routine_create', definition)).rejects.toThrow('Unknown argument')
    await expect(run('routine_delete', { id: theirs.id })).rejects.toThrow('does not belong')
    const { profileId: _profile, ...input } = definition
    const own = await run('routine_create', input) as { id: string }
    const reserved = await run('routine_run', { id: own.id }) as { id: string }
    await routines.tick()
    await run('routine_delete', { id: own.id })
    expect(await run('routine_history')).toMatchObject({ runs: [{ id: reserved.id, profileId: mine.id, status: 'succeeded' }] })
    expect(await run('routine_history', { id: theirs.id })).toEqual({ runs: [] })
    await profiles.update(mine.id, { archived: true })
    await expect(run('memory_forget', { id: saved.id })).rejects.toThrow('archived')
    expect(await run('profile_read')).toMatchObject({ id: mine.id, archived: true })
  } finally { await routines.close() }
})

function barrier() {
  let release!: () => void
  const wait = new Promise<void>(resolve => { release = resolve })
  return { wait, release }
}

it.each(['routine_update', 'routine_pause', 'routine_delete', 'routine_run'])('rechecks profile authority inside serialized %s after reassignment', async tool => {
  const profiles = new AgentProfiles({ version: 1, profiles: [] }, { save: async () => {} })
  const mine = await profiles.create({ name: 'Mine', agent: 'claude-acp' })
  const other = await profiles.create({ name: 'Other', agent: 'claude-acp' })
  const entered = barrier(), resume = barrier()
  let hold = false
  const routines = await AgentRoutines.create({ load: async () => undefined, save: async () => { if (hold) { entered.release(); await resume.wait } } }, {
    runtime: { snapshot: async id => ({ revision: id, input: {} }), acquire: async () => () => {}, lookup: async () => null, start: async () => ({ status: 'succeeded' }) },
  })
  try {
    const routine = await routines.create({ name: 'Original', profileId: mine.id, prompt: 'Report', schedule: { kind: 'daily', timeZone: 'UTC', time: '09:00' } })
    hold = true
    const ownerEdit = routines.update(routine.id, { profileId: other.id })
    await entered.wait
    const dispatch = agentAutomation(profiles, async () => routines, () => {})
    const operation = dispatch({ taskId: 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee', profileId: mine.id, turn: 1 }, tool,
      { id: routine.id, ...(tool === 'routine_update' ? { patch: { name: 'Forbidden' } } : tool === 'routine_pause' ? { paused: true } : {}) })
    const rejection = expect(operation).rejects.toThrow('does not belong')
    resume.release()
    await ownerEdit
    await rejection
    expect(routines.get(routine.id)).toMatchObject({ profileId: other.id, name: 'Original', paused: false })
    expect(routines.history()).toEqual([])
  } finally { resume.release(); await routines.close() }
})

it('merges omitted memory fields after pending owner edits and rejects mutation after pending archive', async () => {
  const entered = barrier(), resume = barrier()
  let hold = false
  const profiles = new AgentProfiles({ version: 1, profiles: [] }, { save: async () => { if (hold) { entered.release(); await resume.wait } } })
  const mine = await profiles.create({ name: 'Mine', agent: 'claude-acp' })
  const saved = await profiles.remember(mine.id, { title: 'Old title', content: 'Old content' })
  const memory = saved.memories[0]!
  const routines = await AgentRoutines.create({ load: async () => undefined, save: async () => {} }, {
    runtime: { snapshot: async () => null, acquire: async () => () => {}, lookup: async () => null, start: async () => ({ status: 'succeeded' }) },
  })
  const dispatch = agentAutomation(profiles, async () => routines, () => {})
  const scope = { taskId: 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee', profileId: mine.id, turn: 1 }
  try {
    hold = true
    const ownerEdit = profiles.remember(mine.id, { title: 'Owner title', content: 'Old content' }, memory.id)
    await entered.wait
    const patch = dispatch(scope, 'memory_update', { id: memory.id, content: 'Agent content' })
    resume.release(); await ownerEdit; await patch
    expect(profiles.get(mine.id).memories[0]).toMatchObject({ title: 'Owner title', content: 'Agent content' })
    const archive = profiles.update(mine.id, { archived: true })
    const rejected = expect(dispatch(scope, 'memory_update', { id: memory.id, content: 'Forbidden' })).rejects.toThrow('archived')
    await archive; await rejected
    expect(profiles.get(mine.id).memories[0]!.content).toBe('Agent content')
  } finally { resume.release(); await routines.close() }
})

it.each(['routine_update', 'routine_pause', 'routine_delete', 'routine_run', 'routine_create'])('rejects queued %s after its profile is archived', async tool => {
  const profiles = new AgentProfiles({ version: 1, profiles: [] }, { save: async () => {} })
  const mine = await profiles.create({ name: 'Mine', agent: 'claude-acp' })
  const entered = barrier(), resume = barrier()
  let hold = false
  const routines = await AgentRoutines.create({ load: async () => undefined, save: async () => { if (hold) { entered.release(); await resume.wait } } }, {
    runtime: { snapshot: async id => profiles.get(id).archived ? null : ({ revision: id, input: {} }), acquire: async () => () => {}, lookup: async () => null, start: async () => ({ status: 'succeeded' }) },
  })
  try {
    const definition = { name: 'Original', prompt: 'Report', schedule: { kind: 'daily', timeZone: 'UTC', time: '09:00' } }
    const routine = await routines.create({ ...definition, profileId: mine.id })
    hold = true
    const pending = routines.update(routine.id, { name: 'Owner edit' })
    await entered.wait
    const dispatch = agentAutomation(profiles, async () => routines, () => {})
    const operation = dispatch({ taskId: 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee', profileId: mine.id, turn: 1 }, tool,
      tool === 'routine_create' ? definition : { id: routine.id, ...(tool === 'routine_update' ? { patch: { name: 'Forbidden' } } : tool === 'routine_pause' ? { paused: true } : {}) })
    const rejection = expect(operation).rejects.toThrow('archived')
    await profiles.update(mine.id, { archived: true })
    resume.release(); await pending; await rejection
    expect(routines.list()).toHaveLength(1)
    expect(routines.get(routine.id)).toMatchObject({ name: 'Owner edit', paused: false })
    expect(routines.history()).toEqual([])
  } finally { resume.release(); await routines.close() }
})
