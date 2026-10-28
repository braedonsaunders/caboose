import { mkdtemp, readFile, rm, stat, writeFile } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { afterEach, expect, it, vi } from 'vitest'
import { AgentProfiles, profileContext, profileWorkspace } from './agent-profiles.js'

const roots: string[] = []
afterEach(async () => { await Promise.all(roots.splice(0).map(root => rm(root, { recursive: true, force: true }))) })
async function setup() {
  const root = await mkdtemp(join(tmpdir(), 'caboose-profiles-')); roots.push(root)
  const path = join(root, 'profiles.json')
  return { path, profiles: await AgentProfiles.open(path) }
}

it('keeps identity and memory across host restart and provider changes', async () => {
  const { path, profiles } = await setup()
  const profile = await profiles.create({ name: 'Research', agent: 'codex-acp', instructions: 'Cite primary sources.' })
  await profiles.remember(profile.id, { title: 'Preference', content: 'Keep reports concise.' })
  await profiles.update(profile.id, { agent: 'claude-acp' })
  const reopened = await AgentProfiles.open(path)
  expect(reopened.get(profile.id)).toMatchObject({ id: profile.id, agent: 'claude-acp', instructions: 'Cite primary sources.', memories: [{ content: 'Keep reports concise.' }] })
  expect(profileContext(reopened.get(profile.id))).toContain('Keep reports concise.')
  expect(profileWorkspace(profile.id)).toBe(`/home/caboose/AgentWorkspaces/${profile.id}`)
  expect((await stat(path)).mode & 0o777).toBe(0o600)
})

it('serializes concurrent edits and does not expose mutable stored records', async () => {
  const { profiles } = await setup()
  const profile = await profiles.create({ name: 'Assistant', agent: 'codex-acp' })
  await Promise.all([
    profiles.update(profile.id, { name: 'Planner' }),
    profiles.update(profile.id, { description: 'Plan the week' }),
    profiles.remember(profile.id, { title: 'Timezone', content: 'America/Toronto' }),
  ])
  const snapshot = profiles.get(profile.id)
  expect(snapshot).toMatchObject({ name: 'Planner', description: 'Plan the week', memories: [{ title: 'Timezone' }] })
  snapshot.memories[0]!.content = 'Mutated'
  expect(profiles.get(profile.id).memories[0]!.content).toBe('America/Toronto')
})

it('keeps archive and memory deletion durable without deleting the agent workspace', async () => {
  const { profiles, path } = await setup()
  const profile = await profiles.create({ name: 'Planner', agent: 'codex-acp' })
  const saved = await profiles.remember(profile.id, { title: 'Temporary', content: 'Remove this' })
  await profiles.forget(profile.id, saved.memories[0]!.id)
  await profiles.update(profile.id, { archived: true })
  const reopened = await AgentProfiles.open(path)
  expect(reopened.list()).toEqual([])
  expect(reopened.list(true)).toMatchObject([{ id: profile.id, archived: true, memories: [] }])
  await reopened.update(profile.id, { archived: false })
  expect(reopened.list()).toHaveLength(1)
})

it('rejects invalid inputs and fails closed on corrupt persisted profiles', async () => {
  const { profiles, path } = await setup()
  for (const bad of [null, [], { name: 'No provider' }, { name: '', agent: 'codex-acp' },
    { name: 'Agent', agent: '../escape' }, { name: 'Agent', agent: 'codex-acp', workspace: '/etc' }]) {
    expect(() => profiles.create(bad)).toThrow()
  }
  expect(() => profileWorkspace('../escape')).toThrow()
  for (const body of ['{', '{"version":2,"profiles":[]}', '{"version":1,"profiles":[{}]}']) {
    await writeFile(path, body)
    await expect(AgentProfiles.open(path)).rejects.toThrow()
    expect(await readFile(path, 'utf8')).toBe(body)
  }
})

it('does not acknowledge failed persistence and recovers for the next write', async () => {
  const save = vi.fn().mockRejectedValueOnce(new Error('disk unavailable')).mockResolvedValue(undefined)
  const profiles = new AgentProfiles({ version: 1, profiles: [] }, { save })
  await expect(profiles.create({ name: 'Not saved', agent: 'codex-acp' })).rejects.toThrow('disk unavailable')
  expect(profiles.list()).toEqual([])
  const profile = await profiles.create({ name: 'Saved', agent: 'codex-acp' })
  expect(profiles.get(profile.id).name).toBe('Saved')
})
