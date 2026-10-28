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
