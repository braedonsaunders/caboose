import { randomUUID } from 'node:crypto'
import { readJsonFile, writePrivateJson } from './settings.js'
import { AgentConflictError, AgentInputError, AgentNotFoundError } from './agents.js'

export interface AgentMemory {
  id: string
  title: string
  content: string
  createdAt: string
  updatedAt: string
}

/** A teammate's identity is independent of its provider and individual conversations. */
export interface AgentProfile {
  id: string
  name: string
  description: string
  instructions: string
  agent: string
  approvals: 'ask' | 'auto'
  archived: boolean
  /** Set only by the host: this computer's implicit identity for ordinary chats with that registry agent. */
  defaultFor?: string
  createdAt: string
  updatedAt: string
  memories: AgentMemory[]
}

interface ProfileState { version: 1; profiles: AgentProfile[] }
export interface ProfilePersistence { save(state: ProfileState): Promise<void> }
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/
const PROVIDER = /^[a-z0-9][a-z0-9._-]{0,63}$/
const MAX_PROFILES = 100
const MAX_MEMORIES = 100
const MAX_MEMORY_TEXT = 64_000
const DEFAULT_INSTRUCTIONS = 'When the owner asks you to remember something, or to do something later or on a schedule, use your Caboose memory and routine tools. A routine runs as a new chat, and its result reaches the owner as a notification.'

function text(value: unknown, name: string, max: number, empty = false): string {
  if (typeof value !== 'string' || value.includes('\0') || value.length > max || (!empty && !value.trim())) {
    throw new AgentInputError(`${name} must be ${empty ? '0' : '1'}–${max} characters`)
  }
  return value.trim()
}

function object(input: unknown): Record<string, unknown> {
  if (!input || typeof input !== 'object' || Array.isArray(input)) throw new AgentInputError('Expected an object')
  return input as Record<string, unknown>
}

function keys(input: Record<string, unknown>, allowed: readonly string[]): void {
  for (const key of Object.keys(input)) if (!allowed.includes(key)) throw new AgentInputError(`Unknown field: ${key}`)
}

function fields(input: Record<string, unknown>, existing?: AgentProfile): Pick<AgentProfile, 'name' | 'description' | 'instructions' | 'agent' | 'approvals' | 'archived'> {
  keys(input, ['name', 'description', 'instructions', 'agent', 'approvals', 'archived'])
  const agent = input.agent ?? existing?.agent
  const approvals = input.approvals ?? existing?.approvals ?? 'ask'
  const archived = input.archived ?? existing?.archived ?? false
  if (typeof agent !== 'string' || !PROVIDER.test(agent)) throw new AgentInputError('Choose an agent from the registry')
  if (approvals !== 'ask' && approvals !== 'auto') throw new AgentInputError('approvals must be ask or auto')
  if (typeof archived !== 'boolean') throw new AgentInputError('archived must be a boolean')
  return {
    name: text(input.name ?? existing?.name, 'name', 80),
    description: text(input.description ?? existing?.description ?? '', 'description', 500, true),
    instructions: text(input.instructions ?? existing?.instructions ?? '', 'instructions', 16_000, true),
    agent, approvals, archived,
  }
}

function date(value: unknown): string {
  if (typeof value !== 'string' || !Number.isFinite(Date.parse(value))) throw new Error('Invalid profile timestamp')
  return value
}

function storedState(value: unknown): ProfileState {
  if (value === undefined) return { version: 1, profiles: [] }
  const state = object(value)
  if (state.version !== 1 || !Array.isArray(state.profiles) || state.profiles.length > MAX_PROFILES) throw new Error('Invalid agent profile store')
  const profiles = state.profiles.map(raw => {
    const p = object(raw)
    if (typeof p.id !== 'string' || !UUID.test(p.id) || !Array.isArray(p.memories) || p.memories.length > MAX_MEMORIES) throw new Error('Invalid agent profile')
    const memories = p.memories.map(rawMemory => {
      const m = object(rawMemory)
      if (typeof m.id !== 'string' || !UUID.test(m.id)) throw new Error('Invalid agent memory')
      return { id: m.id, title: text(m.title, 'title', 120), content: text(m.content, 'content', 8_000), createdAt: date(m.createdAt), updatedAt: date(m.updatedAt) }
    })
    if (new Set(memories.map(m => m.id)).size !== memories.length || memories.reduce((n, m) => n + m.content.length, 0) > MAX_MEMORY_TEXT) throw new Error('Invalid agent memory collection')
    const identity = fields({ name: p.name, description: p.description, instructions: p.instructions, agent: p.agent, approvals: p.approvals, archived: p.archived })
    if (p.defaultFor !== undefined && p.defaultFor !== identity.agent) throw new Error('Invalid default agent profile')
    return { id: p.id, ...identity, ...(p.defaultFor === undefined ? {} : { defaultFor: identity.agent }), createdAt: date(p.createdAt), updatedAt: date(p.updatedAt), memories }
  })
  if (new Set(profiles.map(p => p.id)).size !== profiles.length) throw new Error('Duplicate agent profile')
  const defaults = profiles.flatMap(p => p.defaultFor === undefined ? [] : [p.defaultFor])
  if (new Set(defaults).size !== defaults.length) throw new Error('Duplicate default agent profile')
  return { version: 1, profiles }
}

/** Private host-owned records remain available while the computer is parked. */
export class AgentProfiles {
  private sequence: Promise<unknown> = Promise.resolve()

  constructor(private state: ProfileState, private persistence: ProfilePersistence) {
    this.state = storedState(state)
  }

  static async open(path: string): Promise<AgentProfiles> {
    return new AgentProfiles(storedState(await readJsonFile(path)), { save: state => writePrivateJson(path, state) })
  }

  list(includeArchived = false): AgentProfile[] {
    return structuredClone(this.state.profiles.filter(profile => includeArchived || !profile.archived))
  }

  get(id: string): AgentProfile {
    const profile = this.state.profiles.find(profile => profile.id === id)
    if (!profile) throw new AgentNotFoundError('Agent profile not found')
    return structuredClone(profile)
  }

  /** An update that returns `unchanged` skips the write. */
  private change<T>(update: (state: ProfileState) => T | { unchanged: T }): Promise<T> {
    const operation = this.sequence.then(async () => {
      const next = structuredClone(this.state)
      const outcome = update(next)
      if (outcome && typeof outcome === 'object' && 'unchanged' in outcome) return structuredClone(outcome.unchanged)
      const result = outcome as T
      await this.persistence.save(next)
      this.state = next
      return structuredClone(result)
    })
    this.sequence = operation.catch(() => {})
    return operation
  }

  create(value: unknown): Promise<AgentProfile> {
    const parsed = fields(object(value))
    return this.change(state => {
      if (state.profiles.length >= MAX_PROFILES) throw new AgentConflictError('This computer has reached its agent profile limit')
      const now = new Date().toISOString()
      const profile = { id: randomUUID(), ...parsed, createdAt: now, updatedAt: now, memories: [] }
      state.profiles.push(profile)
      return profile
    })
  }

  update(id: string, value: unknown): Promise<AgentProfile> {
    const input = object(value)
    return this.change(state => {
      const profile = state.profiles.find(profile => profile.id === id)
      if (!profile) throw new AgentNotFoundError('Agent profile not found')
      const next = fields(input, profile)
      if (profile.defaultFor !== undefined && next.agent !== profile.agent) throw new AgentInputError('A default identity keeps its agent; create a profile for another agent')
      Object.assign(profile, next, { updatedAt: new Date().toISOString() })
      return profile
    })
  }

  /**
   * The identity ordinary chats with `agent` use. Serialized and idempotent: concurrent callers
   * get one record. An archived default is returned as is, never replaced or restored; callers
   * refuse to start or continue its chats until the owner restores it.
   */
  ensureDefault(agent: string, name: string): Promise<{ profile: AgentProfile; created: boolean }> {
    if (!PROVIDER.test(agent)) throw new AgentInputError('Choose an agent from the registry')
    const label = name.trim().slice(0, 80) || agent
    return this.change<{ profile: AgentProfile; created: boolean }>(state => {
      const existing = state.profiles.find(profile => profile.defaultFor === agent)
      if (existing) return { unchanged: { profile: existing, created: false } }
      if (state.profiles.length >= MAX_PROFILES) throw new AgentConflictError('This computer has reached its agent profile limit')
      const now = new Date().toISOString()
      const profile: AgentProfile = {
        id: randomUUID(), name: label, description: `The identity of ordinary ${label} chats on this computer.`,
        instructions: DEFAULT_INSTRUCTIONS, agent, approvals: 'ask', archived: false, defaultFor: agent, createdAt: now, updatedAt: now, memories: [],
      }
      state.profiles.push(profile)
      return { profile, created: true }
    })
  }

  remember(id: string, value: unknown, memoryId?: string, requireActive = false): Promise<AgentProfile> {
    const input = object(value)
    keys(input, ['title', 'content'])
    return this.change(state => {
      const profile = state.profiles.find(profile => profile.id === id)
      if (!profile) throw new AgentNotFoundError('Agent profile not found')
      if (requireActive && profile.archived) throw new AgentConflictError('This profile is archived; ask the owner to restore it')
      const previous = memoryId ? profile.memories.find(memory => memory.id === memoryId) : undefined
      if (memoryId && !previous) throw new AgentNotFoundError('Memory not found')
      const title = text(input.title === undefined ? previous?.title : input.title, 'title', 120)
      const content = text(input.content === undefined ? previous?.content : input.content, 'content', 8_000)
      if ((!previous && profile.memories.length >= MAX_MEMORIES) || profile.memories.reduce((n, memory) => n + memory.content.length, 0) - (previous?.content.length ?? 0) + content.length > MAX_MEMORY_TEXT) throw new AgentConflictError('Agent memory is full; edit or remove an existing memory')
      const now = new Date().toISOString()
      if (previous) Object.assign(previous, { title, content, updatedAt: now })
      else profile.memories.push({ id: randomUUID(), title, content, createdAt: now, updatedAt: now })
      profile.updatedAt = now
      return profile
    })
  }

  forget(id: string, memoryId: string, requireActive = false): Promise<AgentProfile> {
    return this.change(state => {
      const profile = state.profiles.find(profile => profile.id === id)
      if (!profile) throw new AgentNotFoundError('Agent profile not found')
      if (requireActive && profile.archived) throw new AgentConflictError('This profile is archived; ask the owner to restore it')
      const index = profile.memories.findIndex(memory => memory.id === memoryId)
      if (index < 0) throw new AgentNotFoundError('Memory not found')
      profile.memories.splice(index, 1)
      profile.updatedAt = new Date().toISOString()
      return profile
    })
  }
}

/** Fixed, identity-derived paths prevent profile edits from choosing arbitrary guest cwd. */
export function profileWorkspace(id: string): string {
  if (!UUID.test(id)) throw new AgentInputError('Invalid agent profile id')
  return `/home/caboose/AgentWorkspaces/${id}`
}

export function profileContext(profile: AgentProfile): string {
  return [
    `You are ${profile.name}.`, profile.description, profile.instructions,
    profile.memories.length ? `Saved memories (editable by the owner):\n${profile.memories.map(memory => `- ${memory.title}: ${memory.content}`).join('\n')}` : '',
  ].filter(Boolean).join('\n\n')
}

/** Resolve owner-controlled identity separately from the untrusted task request. */
export function prepareProfileStart(profiles: AgentProfiles | undefined, input: Record<string, unknown>): {
  input: Record<string, unknown>
  profile?: { id: string; instructions: string; workspace: string }
} {
  if (input.instructions !== undefined || input.workspace !== undefined) throw new AgentInputError('Edit instructions and workspace through an agent profile')
  if (input.profileId === undefined) return { input }
  if (typeof input.profileId !== 'string' || !UUID.test(input.profileId)) throw new AgentInputError('Invalid agent profile id')
  if (!profiles) throw new AgentConflictError('Agent profiles are unavailable')
  const profile = profiles.get(input.profileId)
  if (profile.archived) throw new AgentConflictError('Restore this agent profile before starting a task')
  return {
    input: { ...input, agent: input.agent ?? profile.agent, approvals: input.approvals ?? profile.approvals },
    profile: { id: profile.id, instructions: profileContext(profile), workspace: profileWorkspace(profile.id) },
  }
}
