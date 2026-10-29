import { describe, expect, it, vi } from 'vitest'
import {
  AgentConflictError, AgentInputError, AgentNotFoundError, AgentTasks, LEGACY_SUMMARY, describeRequest, interpretLine, parsePoll, parseRequest,
  readAttachments, transcriptEntry, type AgentEvent, type AgentGuest, type AgentResolver,
} from './agents.js'
import type { AgentLaunch } from './registry.js'
import type { AgentToolJournal } from './agent-tools-journal.js'

const b64 = (text: string | Buffer) => Buffer.from(text).toString('base64')
const line = (event: object) => JSON.stringify(event)

describe('interpretLine', () => {
  it('reads the runner\'s agent-neutral transcript', () => {
    expect(interpretLine(line({ type: 'user', turn: 2, text: 'hi' }))).toEqual({ outputs: [], turn: 2 })
    expect(interpretLine(line({ type: 'text', text: 'Cloning the repo.' })).outputs).toEqual([{ kind: 'text', text: 'Cloning the repo.' }])
    expect(interpretLine(line({ type: 'tool', id: 'c1', title: 'Run tests', kind: 'execute', status: 'pending', detail: 'pnpm test' })).outputs)
      .toEqual([{ kind: 'tool', text: 'Run tests: pnpm test' }])
    expect(interpretLine(line({ type: 'tool', id: 'c1', title: 'Run `pnpm test`', detail: 'pnpm test' })).outputs).toEqual([{ kind: 'tool', text: 'Run `pnpm test`' }])
    expect(interpretLine(line({ type: 'thought', text: 'hmm' })).outputs).toEqual([])
    expect(interpretLine(line({ type: 'tool_update', id: 'c1', status: 'completed' })).outputs).toEqual([])
  })

  it('finds the end of a turn and how it ended', () => {
    expect(interpretLine(line({ type: 'turn_end', turn: 1, stopReason: 'end_turn', summary: 'All tests pass.' })).result)
      .toEqual({ turn: 1, status: 'succeeded', summary: 'All tests pass.' })
    expect(interpretLine(line({ type: 'turn_end', turn: 1, stopReason: 'cancelled', summary: 'Cancelled.' })).result?.status).toBe('cancelled')
    expect(interpretLine(line({ type: 'turn_end', turn: 1, stopReason: 'refusal', summary: 'No.' })).result?.status).toBe('failed')
    expect(interpretLine(line({ type: 'turn_failed', turn: 3, message: 'The agent exited with code 1.' }))).toEqual({
      outputs: [{ kind: 'error', text: 'The agent exited with code 1.' }], result: { turn: 3, status: 'failed', summary: 'The agent exited with code 1.' },
    })
    expect(interpretLine(line({ type: 'auth_required', turn: 1, authMethods: [{ id: 'a', name: 'Account', type: 'agent' }, { id: 'x', name: 'X', type: 'env_var' }] })).result)
      .toEqual({ turn: 1, status: 'failed', summary: '', signIn: [{ id: 'a', name: 'Account', type: 'agent' }] })
    expect(interpretLine(line({ type: 'turn_end', stopReason: 'end_turn' })).result).toBeUndefined()
    expect(interpretLine('not json')).toEqual({ outputs: [] })
  })
})

describe('transcriptEntry', () => {
  it('passes what clients show and drops bookkeeping and bad lines', () => {
    expect(transcriptEntry(line({ type: 'thought', text: 'Checking the tests first.', at: '2026-10-28T12:00:00Z' })))
      .toEqual({ type: 'thought', text: 'Checking the tests first.', at: '2026-10-28T12:00:00Z' })
    expect(transcriptEntry(line({ type: 'tool_update', id: 'c1', title: 'Run tests', kind: 'execute', status: 'completed' })))
      .toEqual({ type: 'tool_update', toolId: 'c1', title: 'Run tests', kind: 'execute', status: 'completed' })
    expect(transcriptEntry(line({ type: 'plan', entries: [{ content: 'Read', status: 'completed' }, { content: 'Fix' }] })))
      .toEqual({ type: 'plan', entries: [{ content: 'Read', status: 'completed' }, { content: 'Fix', status: 'pending' }] })
    expect(transcriptEntry(line({ type: 'permission', requestId: null, tool: 'Edit', summary: 'a.ts', optionId: 'o', kind: 'allow_once', auto: true })))
      .toEqual({ type: 'permission', requestId: null, tool: 'Edit', summary: 'a.ts', auto: true })
    expect(transcriptEntry(line({ type: 'permission_resolved', requestId: REQUEST, outcome: 'selected', allow: false, message: 'not that file' })))
      .toEqual({ type: 'permission_resolved', requestId: REQUEST, allow: false, message: 'not that file' })
    expect(transcriptEntry(line({ type: 'usage', used: 1200, size: 200000, cost: { amount: 0.02, currency: 'USD' } })))
      .toEqual({ type: 'usage', used: 1200, size: 200000, cost: { amount: 0.02, currency: 'USD' } })
    expect(transcriptEntry(line({ type: 'auth_required', turn: 2, message: 'Sign in', authMethods: [] })))
      .toEqual({ type: 'auth_required', turn: 2, message: 'Sign in' })
    expect(transcriptEntry(line({ type: 'session', sessionId: 's', continuity: 'new' }))).toBeUndefined()
    expect(transcriptEntry(line({ type: 'mode', modeId: 'plan' }))).toBeUndefined()
    expect(transcriptEntry(line({ type: 'text', text: '   ' }))).toBeUndefined()
    expect(transcriptEntry(line({ type: 'tool', title: 'no id' }))).toBeUndefined()
    expect(transcriptEntry(line({ type: 'permission_resolved', requestId: '../x', allow: true }))).toBeUndefined()
    expect(transcriptEntry('{')).toBeUndefined()
  })
})

describe('approval requests', () => {
  it('reads the runner\'s request files, summary and options included', () => {
    const id = '6f1c2a8e-1d2b-4c3d-8e4f-5a6b7c8d9e0f'
    const parsed = parseRequest(id, JSON.stringify({ tool: 'Delete build', summary: 'Delete build: rm -rf build', options: [{ id: 'yes', name: 'Allow', kind: 'allow_once' }, { bad: true }], requestedAt: 't' }))
    expect(parsed).toEqual({ request: { id, tool: 'Delete build', summary: 'Delete build: rm -rf build', options: [{ id: 'yes', name: 'Allow', kind: 'allow_once' }] }, requestedAt: 't' })
    expect(parseRequest(id, JSON.stringify({ tool: 'Bash', input: { command: 'ls' } }))?.request.summary).toBe('Bash: ls')
    expect(parseRequest('../x', '{"tool":"a"}')).toBeUndefined()
    expect(describeRequest('Bash', { command: 'x'.repeat(1000) })).toHaveLength(300)
  })
})

describe('readAttachments', () => {
  it('makes names safe and unique and enforces the limits', () => {
    const files = readAttachments([
      { name: '../../etc/passwd', type: 'text/plain', data: b64('a') },
      { name: 'shot.png', type: 'image/png', data: b64('png') },
      { name: 'shot.png', type: 'image/png', data: b64('png2') },
      { name: '.hidden', type: '', data: b64('h') },
    ])
    expect(files.map(file => file.name)).toEqual(['passwd', 'shot.png', 'shot (2).png', 'hidden'])
    expect(files[2]?.data.toString()).toBe('png2')
    expect(() => readAttachments(new Array(5).fill({ name: 'a', type: '', data: b64('a') }))).toThrow(AgentInputError)
    expect(() => readAttachments([{ name: 'a', type: '', data: 'not base64!' }])).toThrow(AgentInputError)
    expect(() => readAttachments([{ name: 'a', type: '', data: '' }])).toThrow(AgentInputError)
    const big = b64(Buffer.alloc(6 * 1024 * 1024))
    expect(() => readAttachments([{ name: 'a', type: '', data: big }, { name: 'b', type: '', data: big }])).toThrow('10 MB')
  })
})

interface FakeTask { alive: boolean; published: Map<string, string>; receipts: Map<string, object>; metadata?: string[]; draft?: object; transcript: Buffer; exitCode: string; stderr: string; approvals: Map<string, { json: string; decision?: string }>; files: Map<string, string>; inbox: string[] }

/**
 * A guest that answers the host's scripts from in-memory task directories: the batched poll,
 * decisions, file writes, starts, replies and cancels. Tests append transcript lines as the
 * runner would.
 */
function fakeGuest() {
  const tasks = new Map<string, FakeTask>()
  const calls: string[][] = []
  let polls = 0
  let beforeCancel: (() => Promise<void>) | undefined
  let beforeLaunch: ((id: string) => void) | undefined
  let claimLaunches = true
  let listing = ''
  const task = (id: string): FakeTask => {
    let entry = tasks.get(id)
    if (!entry) tasks.set(id, entry = { alive: true, published: new Map(), receipts: new Map(), transcript: Buffer.alloc(0), exitCode: '', stderr: '', approvals: new Map(), files: new Map(), inbox: [] })
    return entry
  }
  const idOf = (dir: string) => dir.split('/').at(-1)!
  const guest: AgentGuest = {
    async run(command, args) {
      calls.push([command, ...args])
      const asUser = command === '/usr/sbin/runuser'
      const script = asUser ? args[5]! : args[1] ?? ''
      const rest = asUser ? args.slice(7) : args.slice(3)
      if (script.startsWith('max=$1')) {
        polls++
        const max = Number(rest[0])
        let out = ''
        for (let i = 1; i < rest.length; i += 2) {
          const id = idOf(rest[i]!)
          const state = task(id)
          const data = state.transcript.subarray(Number(rest[i + 1])).subarray(0, max)
          out += `T\t${id}\t${state.exitCode}\t${state.exitCode ? b64(state.stderr) : ''}\t${data.toString('base64')}\n`
          out += `D\t${id}\t${state.draft ? b64(JSON.stringify(state.draft)) : ''}\n`
          for (const [requestId, request] of state.approvals) {
            if (request.decision === undefined) out += `A\t${id}\t${requestId}\t${b64(request.json)}\n`
          }
        }
        return out
      }
      if (script.includes('ls -1t')) return listing || [...tasks.entries()].flatMap(([id, state]) => state.metadata ? [[id, state.metadata[2], '1790000500', state.exitCode, state.alive ? '1' : '0', state.transcript.length,
        b64(state.metadata[1]!), b64(state.transcript.toString().trim().split('\n').reverse().find(line => /"type":"(turn_end|turn_failed|auth_required)"/.test(line)) ?? ''), state.metadata[4],
        Math.max(1, ...state.inbox.filter(x => x !== 'cancel').map(x => JSON.parse(x).turn)), '1', '', b64(state.metadata[3]!), state.files.get(`/home/caboose/Agents/${id}/profile-id`) ?? ''].join('\t')] : []).join('\n')
      if (rest[1]?.startsWith("const fs=require('fs'),p=require('path')")) {
        const state = task(idOf(rest[0]!))
        const model = state.files.get('requested-model.json')
        return JSON.stringify({ ...JSON.parse(state.files.get('models.json') ?? '{}'), ...(model ? { requestedModel: JSON.parse(model) } : {}) })
      }
      if (rest[1]?.startsWith('// delete-agent-task')) { tasks.delete(idOf(rest[0]!)); return '' }
      if (rest[1]?.startsWith('// retire-model-runner')) { task(idOf(rest[0]!)).alive = false; return '' }
      if (script.includes('requested-model.json.part')) {
        task(idOf(rest[0]!)).files.set('requested-model.json', rest[1]!)
        return ''
      }
      if (rest[1]?.startsWith('// caboose confirm journal')) return 'confirmed'
      if (rest[1]?.startsWith('// caboose delivery journal write')) {
        task(idOf(rest[0]!)).files.set('delivery.json', Buffer.from(rest.slice(2).join(''), 'base64').toString('utf8'))
        return ''
      }
      if (rest[1]?.startsWith('// caboose delivery evidence')) {
        const state = task(idOf(rest[0]!)); const name = rest[2]!
        const inbox = state.inbox.find(x => x !== 'cancel' && String(JSON.parse(x).turn).padStart(6, '0') === name) ?? ''
        return JSON.stringify({ journal: state.files.get('delivery.json') ?? '', receiptExists: state.receipts.has(name), receipt: state.receipts.has(name) ? JSON.stringify(state.receipts.get(name)) : '', inbox,
          published: state.published.get(name) ?? '', transcript: state.transcript.toString(), alive: state.alive && !state.exitCode })
      }
      if (script.includes('tail -c "$2" "$1"')) {
        const state = task(rest[0]!.split('/')[4]!)
        return `${state.transcript.length}\t${state.transcript.subarray(-Number(rest[1])).toString('base64')}`
      }
      if (script.includes('printf resolved')) {
        const request = task(idOf(rest[0]!)).approvals.get(rest[1]!)
        if (!request || request.decision !== undefined) return ''
        request.decision = rest[2]!
        return 'resolved'
      }
      if (script.includes(': > "$1"')) task(rest[0]!.split('/')[4]!).files.set(rest[0]!, '')
      if (script.includes('base64 -d')) {
        const path = rest[0]!
        const state = task(path.split('/')[4]!)
        state.files.set(path, (state.files.get(path) ?? '') + Buffer.from(rest.slice(1).join(''), 'base64').toString('latin1'))
      }
      if (script.includes('mv -- "$1.part" "$1"')) {
        const state = task(rest[0]!.split('/')[4]!)
        state.files.set(rest[0]!, state.files.get(`${rest[0]}.part`) ?? '')
        state.files.delete(`${rest[0]}.part`)
      }
      if (script.includes('> task.json')) {
        const state = task(idOf(rest[0]!))
        state.files.set('task.json', rest[5]!)
        state.files.set('delivery.json', rest[7]!)
        state.metadata = rest
        const staged = tasks.get(idOf(rest[10]!))
        if (staged) for (const [path, contents] of staged.files) state.files.set(path.replace(rest[10]!, rest[0]!), contents)
        const message = state.files.get(`${rest[0]}/${rest[6]!.slice(6)}`)!
        state.published.set('000001', message)
        state.inbox.push(message)
        beforeLaunch?.(idOf(rest[0]!))
      }
      if (script.includes('echo launched')) {
        const state = task(idOf(rest[0]!))
        const message = rest[1]!.startsWith('@file:') ? state.files.get(`${rest[0]}/${rest[1]!.slice(6)}`)! : rest[1]!
        const published = state.published.get(rest[3]!)
        if (published !== undefined && published !== message) throw new Error('delivery conflict')
        if (published === undefined) {
          state.inbox.push(message)
          state.published.set(rest[3]!, message)
        }
        if (claimLaunches) state.receipts.set(rest[3]!, { turn: Number(rest[2]), deliveryId: JSON.parse(message).deliveryId, state: 'claimed' })
        state.exitCode = ''; state.alive = true
        return claimLaunches ? 'claimed\n' : 'launched\n'
      }
      if (script.includes('"type":"cancel"')) {
        await beforeCancel?.()
        task(idOf(rest[0]!)).inbox.push('cancel')
      }
      return ''
    },
  }
  return {
    guest, calls, task,
    get polls() { return polls },
    beforeCancel: (hook: () => Promise<void>) => { beforeCancel = hook },
    beforeLaunch: (hook: (id: string) => void) => { beforeLaunch = hook },
    claimOnLaunch: (value: boolean) => { claimLaunches = value },
    setListing: (value: string) => { listing = value; for (const row of value.split('\n')) { const f = row.split('\t'); if (f[0]) { task(f[0]).alive = f[4] === '1'; task(f[0]).exitCode = f[3] ?? '' } } },
    append: (id: string, event: object) => { const state = task(id); state.transcript = Buffer.concat([state.transcript, Buffer.from(JSON.stringify(event) + '\n')]) },
    exit: (id: string, code: string, message = '') => { task(id).exitCode = code; task(id).stderr = message },
    request: (id: string, requestId: string, value: object) => { task(id).approvals.set(requestId, { json: JSON.stringify(value) }) },
    scriptOf: (call: string[] | undefined) => call?.[0] === '/usr/sbin/runuser' ? call[6] : call?.[2],
  }
}

function resolver(defaultAgent: string | null = 'stand-in'): AgentResolver & { launches: string[] } {
  const launches: string[] = []
  return {
    launches,
    defaultAgent: () => defaultAgent,
    async launch(id: string): Promise<AgentLaunch> {
      launches.push(id)
      if (id === 'unknown') throw new AgentNotFoundError('"unknown" is not in the agent registry')
      return { id, name: id === 'stand-in' ? 'Stand-in' : `Agent ${id}`, version: '1.0.0', distribution: 'npx', package: `@example/${id}@1.0.0`, args: [], env: {} }
    },
  }
}

const REQUEST = '6f1c2a8e-1d2b-4c3d-8e4f-5a6b7c8d9e0f'
const user = (turn: number, text = 'x') => ({ type: 'user', turn, text })
const end = (turn: number, summary: string, stopReason = 'end_turn') => ({ type: 'turn_end', turn, stopReason, summary })

function setup(options: { defaultAgent?: string | null; craftServers?: () => Promise<Array<{ name: string; command: string; args: string[]; env: Array<{ name: string; value: string }> }>>; mcpLibrary?: () => Promise<boolean> } = {}) {
  const fake = fakeGuest()
  const events: AgentEvent[] = []
  const release = vi.fn()
  const acquire = vi.fn(() => release)
  const agents = resolver(options.defaultAgent === undefined ? 'stand-in' : options.defaultAgent)
  const tasks = new AgentTasks(() => fake.guest, event => events.push(event), acquire, { resolver: agents, pollMs: 60_000, idleMs: 120_000, craftServers: options.craftServers, ...(options.mcpLibrary ? { mcpLibrary: options.mcpLibrary } : {}) })
  return { fake, events, release, acquire, agents, tasks }
}

describe('AgentTasks', () => {
  it('requires explicit stop for live deletion, releases the lease, and survives restore', async () => {
    const { tasks, fake, events, release } = setup()
    const task = await tasks.start({ prompt: 'hello' })
    await expect(tasks.delete(task.id)).rejects.toThrow('Stop the agent')
    expect(tasks.list()).toHaveLength(1)
    await expect(tasks.delete(task.id, true)).resolves.toBe(true)
    expect(tasks.list()).toEqual([])
    expect(release).toHaveBeenCalledOnce()
    expect(events.at(-1)).toEqual({ type: 'agent.task.deleted', id: task.id })
    await expect(tasks.reply(task.id, { prompt: 'late reply' })).rejects.toThrow(AgentNotFoundError)
    const restored = new AgentTasks(() => fake.guest, () => {}, () => () => {}, { resolver: resolver(), pollMs: 60_000 })
    await restored.restore()
    expect(restored.list()).toEqual([])
    tasks.pause(); restored.pause()
  })

  it('fences a reply queued behind deletion and leaves another computer untouched', async () => {
    const first = setup(), second = setup()
    const id = '11111111-1111-4111-8111-111111111111'
    await first.tasks.start({ prompt: 'first computer' }, { id })
    await second.tasks.start({ prompt: 'second computer' }, { id })
    let entered!: () => void, release!: () => void
    const deleting = new Promise<void>(resolve => { entered = resolve })
    const gate = new Promise<void>(resolve => { release = resolve })
    const run = first.fake.guest.run.bind(first.fake.guest)
    first.fake.guest.run = async (command, args, timeout) => {
      if (args.some(arg => arg.startsWith('// delete-agent-task'))) { entered(); await gate }
      return run(command, args, timeout)
    }
    const removal = first.tasks.delete(id, true)
    await deleting
    const reply = first.tasks.reply(id, { prompt: 'late message' })
    const rejected = expect(reply).rejects.toThrow(AgentNotFoundError)
    release()
    await removal; await rejected
    expect(first.tasks.list()).toEqual([])
    expect(second.tasks.list().map(task => task.prompt)).toEqual(['second computer'])
    first.tasks.pause(); second.tasks.pause()
  })

  it('retains the chat and lease when runner retirement fails', async () => {
    const { tasks, fake, events, release } = setup()
    const task = await tasks.start({ prompt: 'hello' })
    const run = fake.guest.run.bind(fake.guest)
    fake.guest.run = async (command, args, timeout) => {
      if (args.some(arg => arg.startsWith('// delete-agent-task'))) throw new Error('Cannot identify this chat runner')
      return run(command, args, timeout)
    }
    await expect(tasks.delete(task.id, true)).rejects.toThrow('Cannot identify')
    expect(tasks.list()).toHaveLength(1)
    expect(release).not.toHaveBeenCalled()
    expect(events.some(event => event.type === 'agent.task.deleted')).toBe(false)
    tasks.pause()
  })


  it('persists requested models and fences stable task retries by model', async () => {
    const { fake, tasks } = setup()
    const id = '11111111-1111-4111-8111-111111111111'
    const task = await tasks.start({ prompt: 'hello', model: 'provider/model-b' }, { id })
    expect(task.requestedModel).toBe('provider/model-b')
    expect(JSON.parse(fake.task(id).files.get('task.json')!).model).toBe('provider/model-b')
    await expect(tasks.start({ prompt: 'hello', model: 'provider/model-a' }, { id })).rejects.toThrow('different original payload')
    await expect(tasks.start({ prompt: 'hello', model: 'bad\nmodel' })).rejects.toThrow('model must')
    fake.append(id, user(1))
    fake.append(id, { type: 'models', requestedModel: 'provider/model-b', models: { currentModelId: 'provider/model-b', availableModels: [{ id: 'provider/model-b', name: 'Model B' }] } })
    await tasks.poll()
    expect(tasks.list()[0]?.models?.currentModelId).toBe('provider/model-b')
  })

  it('discovers choices for an old idle chat and retires its old runner before setting a model', async () => {
    const { fake, tasks, agents } = setup()
    const task = await tasks.start({ prompt: 'hello' })
    fake.append(task.id, user(1)); fake.append(task.id, end(1, 'done')); await tasks.poll()
    const models = { currentModelId: 'alpha', availableModels: [{ id: 'alpha', name: 'Alpha' }, { id: 'beta', name: 'Beta' }] }
    agents.models = async () => ({ models })
    expect(await tasks.models(task.id)).toEqual({ models, currentModelKnown: false })
    expect(fake.task(task.id).alive).toBe(true)
    expect(await tasks.models(task.id, { model: 'beta' })).toEqual({ requestedModel: 'beta', models, currentModelKnown: false })
    expect(fake.task(task.id).alive).toBe(false)
    expect(JSON.parse(fake.task(task.id).files.get('requested-model.json')!)).toBe('beta')
  })

  it('keeps requested model separate from confirmed current model and fences active changes', async () => {
    const { fake, tasks } = setup()
    const task = await tasks.start({ prompt: 'hello' })
    const models = { currentModelId: 'alpha', availableModels: [{ id: 'alpha', name: 'Alpha' }, { id: 'beta', name: 'Beta' }] }
    fake.task(task.id).files.set('models.json', JSON.stringify({ models }))
    await expect(tasks.models(task.id, { model: 'beta' })).rejects.toThrow('Wait for')
    fake.append(task.id, user(1)); fake.append(task.id, end(1, 'done')); await tasks.poll()
    await expect(tasks.models(task.id, { model: 'invented' })).rejects.toThrow('advertised')
    expect(await tasks.models(task.id, { model: 'beta' })).toEqual({ requestedModel: 'beta', models })
    expect(await tasks.models(task.id)).toEqual({ requestedModel: 'beta', models })
    expect(JSON.parse(fake.task(task.id).files.get('requested-model.json')!)).toBe('beta')
    const restored = new AgentTasks(() => fake.guest, () => {}, () => () => {}, { resolver: resolver(), pollMs: 60_000 })
    await restored.restore()
    expect(restored.list().find(item => item.id === task.id)?.requestedModel).toBe('beta')
    expect(restored.list().find(item => item.id === task.id)?.models).toEqual(models)
    restored.pause()
  })

  it('records catalog servers and honors the per-task opt-out', async () => {
    const server = { name: 'caboose-photo', command: 'photocraft-cli', args: ['mcp'], env: [] }
    const lookup = vi.fn(async () => [server])
    const { fake, tasks } = setup({ craftServers: lookup })
    const first = await tasks.start({ prompt: 'edit' })
    expect(JSON.parse(fake.task(first.id).files.get('task.json')!).craftServers).toEqual([server])
    const second = await tasks.start({ prompt: 'edit', craftMcp: false })
    expect(JSON.parse(fake.task(second.id).files.get('task.json')!).craftServers).toEqual([])
    expect(lookup).toHaveBeenCalledTimes(1)
    await expect(tasks.start({ prompt: 'edit', craftMcp: 'no' })).rejects.toThrow('craftMcp must be a boolean')
  })

  it('gives new chats the MCP Library while it has servers, recording only that, and starts without it when it fails', async () => {
    let active: boolean | Error = true
    const library = vi.fn(async () => { if (active instanceof Error) throw active; return active })
    const { fake, tasks } = setup({ mcpLibrary: library })
    const first = await tasks.start({ prompt: 'search' })
    const config = fake.task(first.id).files.get('task.json')!
    expect(JSON.parse(config).mcpLibrary).toBe(true)
    expect(config).not.toMatch(/token|smithery/i)
    active = false
    expect(JSON.parse(fake.task((await tasks.start({ prompt: 'search' })).id).files.get('task.json')!).mcpLibrary).toBeUndefined()
    active = new Error('Smithery is down')
    expect(JSON.parse(fake.task((await tasks.start({ prompt: 'search' })).id).files.get('task.json')!).mcpLibrary).toBeUndefined()
    expect(library).toHaveBeenCalledTimes(3)
  })

  it('starts a task through the runner, streams its transcript, and releases the lease when the turn ends', async () => {
    const { fake, events, release, tasks } = setup()
    const task = await tasks.start({ prompt: 'Run the tests', agent: 'stand-in' })
    expect(task).toMatchObject({ status: 'running', turns: 1, approvals: 'auto', agent: 'stand-in', agentName: 'Stand-in' })
    expect(fake.calls.some(call => call.join(' ').includes('caboose-display-agent.service'))).toBe(true)
    const state = fake.task(task.id)
    expect(JSON.parse(state.files.get('task.json')!)).toEqual({
      agent: { id: 'stand-in', name: 'Stand-in', version: '1.0.0', distribution: 'npx', package: '@example/stand-in@1.0.0', args: [], env: {} },
      cwd: `/home/caboose/Agents/${task.id}`, approvals: 'auto', idleMs: 120_000, craftServers: [],
    })
    expect(JSON.parse(state.inbox[0]!)).toMatchObject({ type: 'prompt', turn: 1, text: 'Run the tests' })
    const start = fake.calls.find(call => fake.scriptOf(call)?.includes('> task.json'))!
    expect(fake.scriptOf(start)).toContain('setsid sh -c \'node /opt/caboose/agentd/caboose-agentd.mjs run "$PWD"')
    expect(fake.scriptOf(start)).toContain('DISPLAY=:101')
    expect(fake.scriptOf(start)).toContain('. /run/caboose/agent-display.env')
    fake.append(task.id, user(1))
    fake.append(task.id, { type: 'session', sessionId: 's1', continuity: 'new' })
    fake.append(task.id, { type: 'text', text: 'Running pnpm test.' })
    await tasks.poll()
    fake.append(task.id, { type: 'tool', id: 'c', title: 'Run pnpm test', kind: 'execute', status: 'pending' })
    fake.append(task.id, end(1, '42 tests passed.'))
    await tasks.poll()
    expect(events.filter(event => event.type !== 'agent.task.event')).toEqual([
      { type: 'agent.task.started', id: task.id, agent: 'stand-in', agentName: 'Stand-in', prompt: 'Run the tests' },
      { type: 'agent.task.output', id: task.id, kind: 'text', text: 'Running pnpm test.' },
      { type: 'agent.task.output', id: task.id, kind: 'tool', text: 'Run pnpm test' },
      { type: 'agent.task.finished', id: task.id, status: 'succeeded', summary: '42 tests passed.' },
    ])
    expect(tasks.list()[0]).toMatchObject({ status: 'succeeded', summary: '42 tests passed.' })
    expect(release).toHaveBeenCalledTimes(1)
    // The structured events carry the same turn, session bookkeeping left out.
    expect(events.flatMap(event => event.type === 'agent.task.event' ? [event.entry] : [])).toEqual([
      { type: 'user', turn: 1, text: 'x' },
      { type: 'text', text: 'Running pnpm test.' },
      { type: 'tool', toolId: 'c', title: 'Run pnpm test', kind: 'execute', status: 'pending' },
      { type: 'turn_end', turn: 1, stopReason: 'end_turn', summary: '42 tests passed.' },
    ])
    expect(await tasks.transcript(task.id)).toEqual({ entries: events.flatMap(event => event.type === 'agent.task.event' ? [event.entry] : []), truncated: false })
  })

  it('reads a long transcript from its end and refuses unknown tasks', async () => {
    const { fake, tasks } = setup()
    const task = await tasks.start({ prompt: 'Write a lot' })
    fake.append(task.id, user(1))
    for (let i = 0; i < 400; i++) fake.append(task.id, { type: 'text', text: `${i} ${'x'.repeat(10_000)}` })
    fake.append(task.id, end(1, 'Done.'))
    const read = await tasks.transcript(task.id)
    expect(read.truncated).toBe(true)
    expect(read.entries.at(-1)).toEqual({ type: 'turn_end', turn: 1, stopReason: 'end_turn', summary: 'Done.' })
    expect(read.entries.every(entry => entry.type !== 'user')).toBe(true)
    expect(read.entries.length).toBeGreaterThan(150)
    await expect(tasks.transcript('00000000-0000-0000-0000-000000000000')).rejects.toBeInstanceOf(AgentNotFoundError)
  })

  it('runs the default agent, maps the two ids older clients send, and refuses what it cannot run', async () => {
    const { agents, tasks } = setup()
    await tasks.start({ prompt: 'a' })
    await tasks.start({ prompt: 'b', agent: 'claude' })
    await tasks.start({ prompt: 'c', agent: 'codex' })
    await tasks.start({ prompt: 'd', agent: 'goose' })
    expect(agents.launches).toEqual(['stand-in', 'claude-acp', 'codex-acp', 'goose'])
    await expect(tasks.start({ prompt: 'x', agent: 'unknown' })).rejects.toBeInstanceOf(AgentNotFoundError)
    await expect(tasks.start({ prompt: 'x', agent: '../etc' })).rejects.toBeInstanceOf(AgentInputError)
    await expect(tasks.start({ prompt: 'x', agent: 3 })).rejects.toBeInstanceOf(AgentInputError)
    const none = setup({ defaultAgent: null })
    await expect(none.tasks.start({ prompt: 'x' })).rejects.toThrow('Choose an agent')
  })

  it('starts the seat through the driver when it has its own way', async () => {
    const fake = fakeGuest()
    const ensureSeat = vi.fn(async () => {})
    const tasks = new AgentTasks(() => fake.guest, () => {}, () => () => {}, { resolver: resolver(), pollMs: 60_000, ensureSeat })
    await tasks.start({ prompt: 'hi' })
    expect(ensureSeat).toHaveBeenCalledTimes(1)
    expect(fake.calls.some(call => call.join(' ').includes('systemctl'))).toBe(false)
  })

  it('polls every live task with one guest command per tick, and does nothing when idle', async () => {
    const { fake, events, tasks } = setup()
    const a = await tasks.start({ prompt: 'a' })
    const b = await tasks.start({ prompt: 'b' })
    for (const [task, text] of [[a, 'from a'], [b, 'from b']] as const) {
      fake.append(task.id, user(1))
      fake.append(task.id, { type: 'text', text })
    }
    const before = fake.calls.length
    await tasks.poll()
    expect(fake.calls.length - before).toBe(1)
    expect(fake.polls).toBe(1)
    expect(events.filter(event => event.type === 'agent.task.output').map(event => (event as { text: string }).text).sort()).toEqual(['from a', 'from b'])
    fake.append(a.id, end(1, 'a done'))
    fake.append(b.id, end(1, 'b done'))
    await tasks.poll()
    expect(tasks.list().every(task => task.status === 'succeeded')).toBe(true)
    const idle = fake.calls.length
    await tasks.poll()
    expect(fake.calls.length).toBe(idle)
  })

  it('keeps byte offsets exact across multi-byte text and waits for the whole transcript before finishing', async () => {
    const { fake, events, tasks } = setup()
    const task = await tasks.start({ prompt: 'big' })
    // ~1.5 MiB of three-byte characters: more than one tick's budget, split mid-character.
    const text = '✓'.repeat(500_000)
    fake.append(task.id, user(1))
    fake.append(task.id, { type: 'text', text })
    fake.append(task.id, { type: 'text', text: 'tail ✓' })
    fake.exit(task.id, '0')
    await tasks.poll()
    expect(tasks.list()[0]?.status).toBe('running')
    fake.append(task.id, end(1, 'tail ✓'))
    await tasks.poll()
    const outputs = events.filter(event => event.type === 'agent.task.output').map(event => (event as { text: string }).text)
    expect(outputs).toEqual([text, 'tail ✓'])
    expect(tasks.list()[0]).toMatchObject({ status: 'succeeded', summary: 'tail ✓' })
  })

  it('fails a signed-out task with the agent\'s ways to sign in', async () => {
    const { fake, events, tasks } = setup()
    const task = await tasks.start({ prompt: 'hello' })
    const signIn = [{ id: 'login', name: 'Log in', description: 'Opens a browser', type: 'agent' }, { id: 'tty', name: 'Terminal', type: 'terminal' }]
    fake.append(task.id, user(1))
    fake.append(task.id, { type: 'auth_required', turn: 1, message: 'Authentication required', authMethods: signIn })
    await tasks.poll()
    expect(events.at(-1)).toEqual({ type: 'agent.task.finished', id: task.id, status: 'failed', summary: 'Sign in to Stand-in first.', signIn })
    expect(tasks.list()[0]).toMatchObject({ status: 'failed', summary: 'Sign in to Stand-in first.', signIn })
    // A reply after signing in clears it.
    await tasks.reply(task.id, { prompt: 'again' })
    expect(tasks.list()[0]?.signIn).toBeUndefined()
  })

  it('reports a failed turn, and a runner that stopped before its turn ended', async () => {
    const { fake, events, tasks } = setup()
    const failed = await tasks.start({ prompt: 'one' })
    fake.append(failed.id, user(1))
    fake.append(failed.id, { type: 'turn_failed', turn: 1, message: 'The agent exited with code 3.' })
    const died = await tasks.start({ prompt: 'two' })
    fake.exit(died.id, '1', 'caboose-agentd is not installed in this computer')
    await tasks.poll()
    expect(events.filter(event => event.type === 'agent.task.output').map(event => (event as { kind: string }).kind)).toEqual(['error'])
    expect(tasks.list().find(task => task.id === failed.id)).toMatchObject({ status: 'failed', delivery: { state: 'uncertain' } })
    expect(tasks.list().find(task => task.id === died.id)).toMatchObject({ status: 'failed', summary: 'caboose-agentd is not installed in this computer' })
  })

  it('continues a finished conversation through the runner and shows only the new turn', async () => {
    const { fake, events, acquire, tasks } = setup()
    const task = await tasks.start({ prompt: 'write a poem' })
    fake.append(task.id, user(1))
    fake.append(task.id, end(1, 'A long poem.'))
    await tasks.poll()
    const replied = await tasks.reply(task.id, { prompt: '  shorter  ' })
    expect(replied).toMatchObject({ id: task.id, status: 'running', turns: 2, prompt: 'write a poem' })
    expect(replied.summary).toBeUndefined()
    const launch = [...fake.calls].reverse().find(call => fake.scriptOf(call)?.includes('echo launched'))!
    expect(fake.scriptOf(launch)).toContain('echo launched')
    expect(JSON.parse(fake.task(task.id).inbox.at(-1)!)).toMatchObject({ type: 'prompt', turn: 2, text: 'shorter', deliveryId: expect.any(String) })
    expect(events.at(-1)).toEqual({ type: 'agent.task.replied', id: task.id, prompt: 'shorter', turn: 2 })
    expect(acquire).toHaveBeenCalledTimes(2)
    // Late lines of turn 1 are not shown as turn 2, and turn 1's end does not end turn 2.
    fake.append(task.id, { type: 'text', text: 'late from turn 1' })
    fake.append(task.id, end(1, 'A long poem, again.'))
    fake.append(task.id, user(2))
    fake.append(task.id, { type: 'text', text: 'A short poem.' })
    await tasks.poll()
    expect(tasks.list()[0]?.status).toBe('running')
    fake.append(task.id, end(2, 'A short poem.'))
    await tasks.poll()
    expect(tasks.list()[0]).toMatchObject({ status: 'succeeded', summary: 'A short poem.', turns: 2 })
    const texts = events.filter(event => event.type === 'agent.task.output').map(event => (event as { text: string }).text)
    expect(texts).toEqual(['A short poem.'])
  })

  it('streams validated current-turn drafts once and clears them on commit or stop', async () => {
    const { fake, events, tasks } = setup()
    const task = await tasks.start({ prompt: 'stream' })
    fake.append(task.id, user(1))
    const state = fake.task(task.id)
    state.draft = { turn: 1, after: state.transcript.length, kind: 'text', text: 'Hello' }
    await tasks.poll()
    expect(tasks.list()[0]?.draft).toEqual({ turn: 1, kind: 'text', text: 'Hello' })
    await tasks.poll()
    expect(events.filter(e => e.type === 'agent.task.draft')).toHaveLength(1)
    fake.append(task.id, { type: 'text', text: 'Hello world' })
    // Even a stale file cannot duplicate text now committed in the transcript.
    await tasks.poll()
    expect(tasks.list()[0]?.draft).toBeUndefined()
    for (const draft of [
      { turn: 2, after: state.transcript.length, kind: 'text', text: 'wrong turn' },
      { turn: 1, after: state.transcript.length + 10, kind: 'text', text: 'ahead of transcript' },
      { turn: 1, after: state.transcript.length, kind: 'tool', text: 'invalid' },
      { turn: 1, after: state.transcript.length, kind: 'text', text: 'x'.repeat(16_001) },
    ]) { state.draft = draft; await tasks.poll(); expect(tasks.list()[0]?.draft).toBeUndefined() }
    state.draft = { turn: 1, after: state.transcript.length, kind: 'thought', text: 'Thinking' }
    await tasks.poll()
    await tasks.cancel(task.id)
    expect(tasks.list()[0]?.draft).toBeUndefined()
  })

  it('keeps queued files distinct and delivers them both automatically and with Send Now', async () => {
    const { fake, tasks } = setup()
    const task = await tasks.start({ prompt: 'read these later' })
    const file = { name: 'notes.txt', type: 'text/plain', data: b64('hello') }
    await Promise.all([
      tasks.reply(task.id, { prompt: 'first', attachments: [file] }),
      tasks.reply(task.id, { prompt: 'second', attachments: [file] }),
    ])
    const paths = tasks.list()[0]!.queuedAttachments!.flat()
    expect(new Set(paths).size).toBe(2)
    expect(paths.every(path => fake.task(task.id).files.get(path) === 'hello')).toBe(true)
    await tasks.sendNow(task.id)
    let message = JSON.parse(fake.task(task.id).inbox.at(-1)!)
    expect(message.text).toBe('first\n\nsecond')
    expect(message.attachments.map((a: { path: string }) => a.path)).toEqual(paths)
    expect(tasks.list()[0]!.queuedAttachments).toBeUndefined()
    await tasks.reply(task.id, { prompt: 'third', attachments: [file] })
    fake.append(task.id, user(2))
    fake.append(task.id, end(2, 'done'))
    await tasks.poll()
    await vi.waitFor(() => expect(tasks.list()[0]?.turns).toBe(3))
    message = JSON.parse(fake.task(task.id).inbox.at(-1)!)
    expect(message.attachments[0]).toMatchObject({ name: 'notes.txt', mimeType: 'text/plain' })
    expect(message.text).toBe('third')
  })

  it('claims Send Now before cancellation yields to a normal polled turn end', async () => {
    const { fake, tasks, events, release } = setup()
    const task = await tasks.start({ prompt: 'working' })
    await tasks.reply(task.id, { prompt: 'queued', attachments: [{ name: 'notes.txt', data: b64('contents') }] })
    let resume!: () => void
    let entered!: () => void
    const gate = new Promise<void>(resolve => { resume = resolve })
    const cancelling = new Promise<void>(resolve => { entered = resolve })
    fake.beforeCancel(async () => { entered(); await gate })
    const sending = tasks.sendNow(task.id)
    await cancelling
    fake.append(task.id, user(1))
    fake.append(task.id, end(1, 'finished just before cancellation'))
    await tasks.poll()
    expect(release).not.toHaveBeenCalled()
    expect(fake.task(task.id).inbox).toHaveLength(1)
    resume()
    await sending
    const prompts = fake.task(task.id).inbox.filter(value => value !== 'cancel').map(value => JSON.parse(value))
    expect(prompts.filter(prompt => prompt.turn === 2)).toHaveLength(1)
    expect(prompts.at(-1)).toMatchObject({ turn: 2, text: 'queued', attachments: [{ name: 'notes.txt' }] })
    expect(tasks.list()[0]?.turns).toBe(2)
    expect(events.filter(event => event.type === 'agent.task.replied')).toHaveLength(1)
    expect(events.filter(event => event.type === 'agent.task.finished')).toHaveLength(0)
  })

  it('restores waiting files when Send Now delivery fails after the old turn finishes', async () => {
    const { fake, tasks, release } = setup()
    const task = await tasks.start({ prompt: 'working' })
    await tasks.reply(task.id, { prompt: 'queued', attachments: [{ name: 'notes.txt', data: b64('contents') }] })
    const paths = tasks.list()[0]!.queuedAttachments
    fake.beforeCancel(async () => {
      fake.append(task.id, user(1)); fake.append(task.id, end(1, 'done'))
      await tasks.poll()
    })
    const run = fake.guest.run
    fake.guest.run = async (command, args, timeout) => {
      if (args.some(arg => arg.includes('echo launched'))) throw new Error('delivery failed')
      return run(command, args, timeout)
    }
    await expect(tasks.sendNow(task.id)).rejects.toThrow('delivery failed')
    expect(tasks.list()[0]).toMatchObject({ queued: ['queued'], queuedAttachments: paths, status: 'succeeded' })
    expect(release).toHaveBeenCalledTimes(1)
    fake.guest.run = run
    await tasks.sendNow(task.id)
    expect(tasks.list()[0]).toMatchObject({ status: 'running', turns: 2 })
    expect(tasks.list()[0]!.queued).toBeUndefined()
  })

  it('bounds files across concurrent queued replies and supports files on a finished reply', async () => {
    const { fake, tasks } = setup()
    const task = await tasks.start({ prompt: 'x' })
    const file = { name: 'a.txt', data: b64('a') }
    const replies = await Promise.allSettled(Array.from({ length: 5 }, () => tasks.reply(task.id, { prompt: 'more', attachments: [file] })))
    expect(replies.filter(r => r.status === 'fulfilled')).toHaveLength(4)
    expect(tasks.list()[0]!.queuedAttachments!.flat()).toHaveLength(4)
    await tasks.cancel(task.id)
    await tasks.reply(task.id, { prompt: 'again', attachments: [file] })
    expect(JSON.parse(fake.task(task.id).inbox.at(-1)!).attachments).toHaveLength(1)
    await expect(tasks.reply(task.id, { prompt: 'bad', attachments: [{ name: 'bad', data: '!' }] })).rejects.toThrow()
  })

  it('refuses replies it cannot honour', async () => {
    const { tasks } = setup()
    await expect(tasks.reply('11111111-1111-4111-8111-111111111111', { prompt: 'x' })).rejects.toBeInstanceOf(AgentNotFoundError)
    await expect(tasks.reply('../../etc', { prompt: 'x' })).rejects.toBeInstanceOf(AgentNotFoundError)
    const task = await tasks.start({ prompt: 'x' })
    await tasks.cancel(task.id)
    await expect(tasks.reply(task.id, { prompt: '' })).rejects.toBeInstanceOf(AgentInputError)
    // A cancelled task can still be continued.
    await expect(tasks.reply(task.id, { prompt: 'more' })).resolves.toMatchObject({ status: 'running', turns: 2 })
  })

  it('holds replies sent while the agent works and sends them together as its next turn', async () => {
    const { fake, events, release, tasks } = setup()
    const task = await tasks.start({ prompt: 'Tidy Downloads' })
    fake.append(task.id, user(1))
    await expect(tasks.reply(task.id, { prompt: 'how is it going?' })).resolves.toMatchObject({ status: 'running', turns: 1, queued: ['how is it going?'] })
    await tasks.reply(task.id, { prompt: 'skip the PDFs' })
    expect(tasks.list()[0]!.queued).toEqual(['how is it going?', 'skip the PDFs'])
    expect(events.filter(event => event.type === 'agent.task.queued').at(-1)).toEqual({ type: 'agent.task.queued', id: task.id, queued: ['how is it going?', 'skip the PDFs'] })
    fake.append(task.id, end(1, 'Moved 40 files.'))
    await tasks.poll()
    await vi.waitFor(() => expect(tasks.list()[0]).toMatchObject({ status: 'running', turns: 2 }))
    expect(tasks.list()[0]!.queued).toBeUndefined()
    expect(JSON.parse(fake.task(task.id).inbox.at(-1)!)).toMatchObject({ type: 'prompt', turn: 2, text: 'how is it going?\n\nskip the PDFs' })
    // The turn in between is not announced as finished, and the lease is never let go.
    expect(events.some(event => event.type === 'agent.task.finished')).toBe(false)
    expect(events.at(-1)).toMatchObject({ type: 'agent.task.replied', turn: 2, prompt: 'how is it going?\n\nskip the PDFs' })
    expect(release).toHaveBeenCalledTimes(1)
    fake.append(task.id, user(2))
    fake.append(task.id, end(2, 'Going well; PDFs left alone.'))
    await tasks.poll()
    expect(events.at(-1)).toEqual({ type: 'agent.task.finished', id: task.id, status: 'succeeded', summary: 'Going well; PDFs left alone.' })
  })

  it('drops waiting replies when stopped, and keeps them for the next reply after a sign-in', async () => {
    const { fake, tasks } = setup()
    const stopped = await tasks.start({ prompt: 'a' })
    await tasks.reply(stopped.id, { prompt: 'b' })
    await tasks.cancel(stopped.id)
    expect(tasks.list().find(task => task.id === stopped.id)!.queued).toBeUndefined()
    const signedOut = await tasks.start({ prompt: 'c' })
    await tasks.reply(signedOut.id, { prompt: 'd' })
    fake.append(signedOut.id, user(1))
    fake.append(signedOut.id, { type: 'auth_required', turn: 1, authMethods: [{ id: 'a', name: 'Account', type: 'agent' }] })
    await tasks.poll()
    expect(tasks.list().find(task => task.id === signedOut.id)).toMatchObject({ status: 'failed', queued: ['d'] })
    await tasks.reply(signedOut.id, { prompt: 'e' })
    expect(JSON.parse(fake.task(signedOut.id).inbox.at(-1)!)).toMatchObject({ type: 'prompt', turn: 2, text: 'd\n\ne' })
    expect(tasks.list().find(task => task.id === signedOut.id)!.queued).toBeUndefined()
    const busy = await tasks.start({ prompt: 'f' })
    for (let i = 0; i < 10; i++) await tasks.reply(busy.id, { prompt: `${i}` })
    await expect(tasks.reply(busy.id, { prompt: 'one too many' })).rejects.toBeInstanceOf(AgentConflictError)
  })

  it('asks the owner before acting, for any agent, and passes the chosen option back', async () => {
    const { fake, events, tasks } = setup()
    await expect(tasks.start({ prompt: 'x', approvals: 'sometimes' })).rejects.toBeInstanceOf(AgentInputError)
    const task = await tasks.start({ prompt: 'clean up', agent: 'codex', approvals: 'ask' })
    expect(task.approvals).toBe('ask')
    expect(JSON.parse(fake.task(task.id).files.get('task.json')!).approvals).toBe('ask')
    const options = [{ id: 'yes', name: 'Allow', kind: 'allow_once' }, { id: 'always', name: 'Always allow', kind: 'allow_always' }, { id: 'no', name: 'Reject', kind: 'reject_once' }]
    fake.request(task.id, REQUEST, { tool: 'Delete build', kind: 'delete', summary: 'Delete build: rm -rf build', input: { command: 'rm -rf build' }, options, requestedAt: '2026-10-28T00:00:00.000Z' })
    fake.request(task.id, 'not-a-uuid', { tool: 'Bash', input: {} })
    await tasks.poll()
    await tasks.poll()
    const request = { id: REQUEST, tool: 'Delete build', summary: 'Delete build: rm -rf build', options }
    expect(events.filter(event => event.type === 'agent.task.approval')).toEqual([{ type: 'agent.task.approval', id: task.id, request }])
    expect(tasks.list()[0]?.pendingApproval).toEqual(request)
    await expect(tasks.resolveApproval(task.id, '../x', { allow: true })).rejects.toBeInstanceOf(AgentInputError)
    await expect(tasks.resolveApproval(task.id, REQUEST, { allow: 'yes' })).rejects.toBeInstanceOf(AgentInputError)
    await expect(tasks.resolveApproval(task.id, REQUEST, { allow: true, optionId: 7 })).rejects.toBeInstanceOf(AgentInputError)
    expect(await tasks.resolveApproval(task.id, REQUEST, { allow: true, optionId: 'always' })).toBe(true)
    expect(JSON.parse(fake.task(task.id).approvals.get(REQUEST)!.decision!)).toEqual({ allow: true, optionId: 'always' })
    expect(events.at(-1)).toEqual({ type: 'agent.task.approval.resolved', id: task.id, requestId: REQUEST, allow: true })
    expect(tasks.list()[0]?.pendingApproval).toBeUndefined()
    expect(await tasks.resolveApproval(task.id, REQUEST, { allow: false, message: 'No.' })).toBe(false)
  })

  it('writes attachments into the task and hands them to the runner with the prompt', async () => {
    const { fake, tasks } = setup()
    const png = Buffer.from([0x89, 0x50, 0x4e, 0x47, 0, 255])
    const task = await tasks.start({ prompt: 'What is in this picture?', attachments: [
      { name: 'photo.png', type: 'image/png', data: png.toString('base64') },
      { name: 'a/../notes.txt', data: b64('notes') },
    ] })
    const dir = `/home/caboose/Agents/${task.id}`
    expect(task.attachments).toEqual([`${dir}/attachments/photo.png`, `${dir}/attachments/notes.txt`])
    expect(fake.task(task.id).files.get(`${dir}/attachments/photo.png`)).toBe(png.toString('latin1'))
    expect(fake.task(task.id).files.get(`${dir}/attachments/notes.txt`)).toBe('notes')
    expect(JSON.parse(fake.task(task.id).inbox[0]!)).toMatchObject({ type: 'prompt', turn: 1, text: 'What is in this picture?', attachments: [
      { path: `${dir}/attachments/photo.png`, name: 'photo.png', mimeType: 'image/png' },
      { path: `${dir}/attachments/notes.txt`, name: 'notes.txt' },
    ] })
    expect(tasks.list()[0]?.prompt).toBe('What is in this picture?')
  })

  it('preserves task data when a start command fails ambiguously', async () => {
    const fake = fakeGuest()
    const guest: AgentGuest = { run: async (command, args, timeout) => {
      if (args[5]?.includes('setsid')) throw new Error('caboose-agentd is not installed in this computer')
      return fake.guest.run(command, args, timeout)
    } }
    const tasks = new AgentTasks(() => guest, () => {}, () => () => {}, { resolver: resolver(), pollMs: 60_000 })
    await expect(tasks.start({ prompt: 'x' })).rejects.toBeInstanceOf(AgentConflictError)
    await expect(tasks.start({ prompt: 'x' })).rejects.toThrow('This computer has no agent runner')
    expect(fake.calls.some(call => fake.scriptOf(call)?.includes('rm -rf'))).toBe(false)
    expect(tasks.list()).toEqual([])
  })

  it('cancels a running turn through the runner', async () => {
    const { fake, events, tasks } = setup()
    const task = await tasks.start({ prompt: 'long job' })
    expect(await tasks.cancel(task.id)).toBe(true)
    expect(fake.task(task.id).inbox.at(-1)).toBe('cancel')
    expect(fake.calls.some(call => fake.scriptOf(call)?.includes('kill -CONT'))).toBe(true)
    expect(tasks.list()[0]).toMatchObject({ status: 'cancelled', summary: 'Cancelled.' })
    expect(await tasks.cancel(task.id)).toBe(false)
    expect(events.filter(event => event.type === 'agent.task.finished')).toHaveLength(1)
  })

  it('pauses a task for take-over and continues it on hand-back', async () => {
    const { fake, events, tasks } = setup()
    const task = await tasks.start({ prompt: 'fill the form' })
    expect(await tasks.resumeTask(task.id)).toBe(false)
    expect(await tasks.pauseTask(task.id)).toBe(true)
    expect(fake.calls.at(-1)?.join(' ')).toContain('kill -STOP -- -"$pid"')
    expect(tasks.list()[0]?.status).toBe('paused')
    expect(await tasks.resumeTask(task.id)).toBe(true)
    expect(fake.calls.at(-1)?.join(' ')).toContain('kill -CONT')
    await tasks.pauseTask(task.id)
    expect(await tasks.cancel(task.id)).toBe(true)
    expect(events.map(event => event.type)).toEqual(['agent.task.started', 'agent.task.paused', 'agent.task.resumed',
      'agent.task.paused', 'agent.task.finished'])
  })

  it('restores tasks from the guest after a host restart, still able to reply', async () => {
    const running = '11111111-1111-4111-8111-111111111111'
    const done = '22222222-2222-4222-8222-222222222222'
    const orphan = '33333333-3333-4333-8333-333333333333'
    const waiting = '44444444-4444-4444-8444-444444444444'
    const legacy = '55555555-5555-4555-8555-555555555555'
    const legacyFailed = '66666666-6666-4666-8666-666666666666'
    const listing = [
      [running, 'goose', '1790000500', '', '1', '512', b64('keep going'), b64(line(end(1, 'earlier turn'))), 'auto', '2', '1', '', b64('goose')],
      [done, 'stand-in', '1790000400', '0', '0', '900', b64('run tests'), b64(line(end(3, 'All green.'))), 'ask', '3', '1', b64('shot.png\n'), b64('Stand-in')],
      [orphan, 'stand-in', '1790000300', '', '0', '10', b64('lost'), '', 'auto', '1', '1', '', b64('Stand-in')],
      [waiting, 'stand-in', '1790000200', '', '1', '40', b64('signed out'), b64(line({ type: 'auth_required', turn: 1, authMethods: [{ id: 'a', name: 'A', type: 'agent' }] })), 'auto', '1', '1', '', b64('Stand-in')],
      [legacy, 'claude', '1790000100', '0', '0', '10', b64('old'), '', 'auto', '1', '0', '', ''],
      [legacyFailed, 'codex', '1790000050', '1', '0', '10', b64('older'), '', 'auto', '1', '0', '', ''],
    ].map(fields => fields.join('\t')).join('\n')
    const { fake, events, acquire, tasks } = setup()
    fake.setListing(listing)
    await tasks.restore()
    await tasks.restore()
    expect(tasks.list().map(task => [task.id, task.status, task.agent])).toEqual([
      [running, 'running', 'goose'], [done, 'succeeded', 'stand-in'], [orphan, 'failed', 'stand-in'], [waiting, 'failed', 'stand-in'], [legacy, 'succeeded', 'claude-acp'],
      [legacyFailed, 'failed', 'codex-acp'],
    ])
    // A task from before the runner says where its transcript is, not that a runner failed.
    expect(tasks.list()[5]!.summary).toBe(`${LEGACY_SUMMARY} /home/caboose/Agents/${legacyFailed}/transcript.jsonl.`)
    expect(tasks.list()[0]).toMatchObject({ prompt: 'keep going', turns: 2, agentName: 'goose' })
    expect(tasks.list()[1]).toMatchObject({ summary: 'All green.', turns: 3, approvals: 'ask', attachments: [`/home/caboose/Agents/${done}/attachments/shot.png`] })
    expect(tasks.list()[3]).toMatchObject({ summary: 'Sign in to Stand-in first.', signIn: [{ id: 'a', name: 'A', type: 'agent' }] })
    // Only the task whose turn is still running holds the computer awake.
    expect(acquire).toHaveBeenCalledTimes(1)
    expect(events).toEqual([])
    await tasks.reply(done, { prompt: 'and lint' })
    expect(JSON.parse(fake.task(done).inbox.at(-1)!)).toMatchObject({ type: 'prompt', turn: 4, text: 'and lint', deliveryId: expect.any(String) })
    await tasks.poll()
    const poll = fake.calls.find(call => fake.scriptOf(call)?.startsWith('max=$1'))!
    expect(poll.slice(poll.indexOf(`/home/caboose/Agents/${done}`), poll.indexOf(`/home/caboose/Agents/${done}`) + 2)).toEqual([`/home/caboose/Agents/${done}`, '900'])
    // The running task's current turn is shown as it continues.
    fake.task(running).transcript = Buffer.alloc(512)
    fake.append(running, { type: 'text', text: 'still at it' })
    await tasks.poll()
    expect(events.some(event => event.type === 'agent.task.output' && event.text === 'still at it')).toBe(true)
    await expect(tasks.reply(legacy, { prompt: 'retry' })).rejects.toThrow('earlier version of Caboose')
    tasks.pause()
  })

  it('rejects bad input and a parked computer', async () => {
    const tasks = new AgentTasks(() => undefined, () => {}, () => () => {}, { resolver: resolver(), pollMs: 60_000 })
    await expect(tasks.start({ prompt: '' })).rejects.toBeInstanceOf(AgentInputError)
    await expect(tasks.start({ prompt: 'x' })).rejects.toThrow('computer is not running')
  })

  it('releases running and paused task leases after a cold restart', async () => {
    const { release, tasks } = setup()
    const first = await tasks.start({ prompt: 'first' })
    await tasks.start({ prompt: 'second' })
    await tasks.pauseTask(first.id)
    tasks.computerRestarted()
    expect(tasks.list().every(task => task.status === 'failed' && task.summary?.includes('restarted'))).toBe(true)
    expect(release).toHaveBeenCalledTimes(2)
    tasks.computerRestarted()
    expect(release).toHaveBeenCalledTimes(2)
  })
})

describe('parsePoll', () => {
  it('ignores lines that are not task or request records', () => {
    const id = '11111111-1111-4111-8111-111111111111'
    const reports = parsePoll(`garbage\nT\t${id}\t0\t${b64('err')}\t${b64('{"a":1}\n')}\nA\t${id}\t${REQUEST}\t${b64('{}')}\nA\t${id}\t../x\t\nT\tnot-an-id\t\t\t\n`)
    expect([...reports.keys()]).toEqual([id])
    expect(reports.get(id)).toMatchObject({ exitCode: '0', stderr: 'err', requests: [{ id: REQUEST, json: '{}' }] })
    expect(reports.get(id)?.data.toString()).toBe('{"a":1}\n')
  })
})

describe('durable admission and recovery', () => {
  async function restart(s: ReturnType<typeof setup>) {
    s.tasks.pause()
    const events: AgentEvent[] = []
    const release = vi.fn()
    const tasks = new AgentTasks(() => s.fake.guest, event => events.push(event), () => release,
      { resolver: resolver(), pollMs: 60_000 })
    await tasks.restore()
    tasks.pause()
    return { tasks, events, release }
  }
  const journal = (s: ReturnType<typeof setup>, id: string) => JSON.parse(s.fake.task(id).files.get('delivery.json')!)
  const writes = (s: ReturnType<typeof setup>) => s.fake.calls.filter(call => call.some(arg => arg.startsWith('// caboose delivery journal write')))

  it('restores ordered queued replies and their staged files across a host restart', async () => {
    const s = setup()
    const t = await s.tasks.start({ prompt: 'work' })
    const files = [{ name: 'notes.txt', data: b64('durable contents') }]
    await s.tasks.reply(t.id, { prompt: 'first', attachments: files, operationId: 'reply-1' })
    await s.tasks.reply(t.id, { prompt: 'second', operationId: 'reply-2' })
    const paths = t.queuedAttachments
    const r = await restart(s)
    expect(r.tasks.list()[0]).toMatchObject({ queued: ['first', 'second'], queuedAttachments: paths })
    expect(s.fake.task(t.id).files.get(paths![0]![0]!)).toBe('durable contents')
    s.fake.append(t.id, user(1)); s.fake.append(t.id, end(1, 'done'))
    await r.tasks.poll()
    expect(r.tasks.list()[0]).toMatchObject({ turns: 2, status: 'running' })
    expect(JSON.parse(s.fake.task(t.id).inbox.at(-1)!)).toMatchObject({ text: 'first\n\nsecond', attachments: [{ path: paths![0]![0] }] })
    expect(journal(s, t.id).queue).toEqual([])
  })

  it('deduplicates stable task ids concurrently and after restart, comparing original bytes and options', async () => {
    const s = setup()
    const id = '11111111-1111-4111-8111-111111111111'
    const input = { prompt: 'work', attachments: [{ name: 'a.txt', data: b64('one') }], craftMcp: false }
    const [a, b] = await Promise.all([s.tasks.start(input, { id }), s.tasks.start(input, { id })])
    expect(a.id).toBe(b.id)
    expect(s.fake.task(id).inbox).toHaveLength(1)
    const r = await restart(s)
    await expect(r.tasks.start(input, { id })).resolves.toMatchObject({ id, turns: 1, attachments: a.attachments })
    expect(s.fake.task(id).inbox).toHaveLength(1)
    await expect(r.tasks.start({ ...input, attachments: [{ name: 'a.txt', data: b64('two') }] }, { id })).rejects.toBeInstanceOf(AgentConflictError)
    await expect(r.tasks.start({ ...input, prompt: ' work' }, { id })).rejects.toBeInstanceOf(AgentConflictError)
    await expect(r.tasks.start(input, { id: '../bad' })).rejects.toBeInstanceOf(AgentInputError)
    await expect(r.tasks.start(input, { id: '-'.repeat(36) })).rejects.toBeInstanceOf(AgentInputError)
  })

  it('deduplicates opaque reply operations before and after delivery and restart', async () => {
    const s = setup()
    const t = await s.tasks.start({ prompt: 'work' })
    const input = { prompt: 'reply', attachments: [{ name: 'n.txt', data: b64('one') }], operationId: ' opaque/ key ? ' }
    await Promise.all([s.tasks.reply(t.id, input), s.tasks.reply(t.id, input)])
    expect(t.queued).toEqual(['reply'])
    const r = await restart(s)
    await r.tasks.reply(t.id, input)
    expect(r.tasks.list()[0]?.queued).toEqual(['reply'])
    await expect(r.tasks.reply(t.id, { ...input, attachments: [{ name: 'n.txt', data: b64('two') }] })).rejects.toBeInstanceOf(AgentConflictError)
    s.fake.append(t.id, user(1)); s.fake.append(t.id, end(1, 'done'))
    await r.tasks.poll()
    await r.tasks.reply(t.id, input)
    expect(r.tasks.list()[0]?.turns).toBe(2)
    expect(s.fake.task(t.id).inbox.filter(x => x !== 'cancel' && JSON.parse(x).turn === 2)).toHaveLength(1)
    expect(journal(s, t.id).operations).toMatchObject([{ id: input.operationId, turn: 2 }])
    for (const operationId of ['', 'x'.repeat(201), 'bad\nkey', 42]) {
      await expect(r.tasks.reply(t.id, { prompt: 'x', operationId })).rejects.toBeInstanceOf(AgentInputError)
    }
  })

  it('does not return admission success before the write finishes; poll and Send Now preserve order', async () => {
    const s = setup()
    const t = await s.tasks.start({ prompt: 'work' })
    let unblock!: () => void, entered!: () => void
    const gate = new Promise<void>(resolve => { unblock = resolve })
    const writing = new Promise<void>(resolve => { entered = resolve })
    const run = s.fake.guest.run
    let delay = true
    s.fake.guest.run = async (command, args, timeout) => {
      if (delay && args.some(arg => arg.startsWith('// caboose delivery journal write'))) { delay = false; entered(); await gate }
      return run(command, args, timeout)
    }
    let admitted = false
    const reply = s.tasks.reply(t.id, { prompt: 'first', operationId: 'one' }).then(() => { admitted = true })
    await writing
    const second = s.tasks.reply(t.id, { prompt: 'second', operationId: 'two' })
    const sending = s.tasks.sendNow(t.id)
    s.fake.append(t.id, user(1)); s.fake.append(t.id, end(1, 'done'))
    const polling = s.tasks.poll()
    expect(admitted).toBe(false)
    expect(journal(s, t.id).queue).toHaveLength(0)
    unblock()
    await Promise.all([reply, second, sending, polling])
    expect(journal(s, t.id).operations.map((op: any) => op.id)).toEqual(['one', 'two'])
    const prompts = s.fake.task(t.id).inbox.filter(x => x !== 'cancel').map(x => JSON.parse(x))
    expect(prompts.filter(x => x.turn > 1).map(x => x.text).join('\n\n')).toBe('first\n\nsecond')
    expect(writes(s).length).toBeGreaterThan(1)
  })

  it('rejects a failed admission write and recognizes a write that committed before its response failed', async () => {
    const s = setup()
    const t = await s.tasks.start({ prompt: 'work' })
    const run = s.fake.guest.run
    s.fake.guest.run = async (command, args, timeout) => {
      if (args.some(arg => arg.startsWith('// caboose delivery journal write'))) throw Error('disk write failed')
      return run(command, args, timeout)
    }
    await expect(s.tasks.reply(t.id, { prompt: 'reply', operationId: 'one' })).rejects.toThrow('disk write failed')
    expect(t.queued).toBeUndefined()
    expect(journal(s, t.id).queue).toHaveLength(0)
    s.fake.guest.run = async (command, args, timeout) => {
      const out = await run(command, args, timeout)
      if (args.some(arg => arg.startsWith('// caboose delivery journal write'))) throw Error('response lost after rename')
      return out
    }
    await s.tasks.reply(t.id, { prompt: 'reply', operationId: 'one' })
    expect(t.queued).toEqual(['reply'])
    const r = await restart(s)
    await r.tasks.reply(t.id, { prompt: 'reply', operationId: 'one' })
    expect(r.tasks.list()[0]?.queued).toEqual(['reply'])
  })

  it('finds a stable task when its launch response was lost', async () => {
    const s = setup()
    const run = s.fake.guest.run
    s.fake.guest.run = async (command, args, timeout) => {
      const out = await run(command, args, timeout)
      if (args.some(arg => arg.includes('> task.json'))) throw Error('start response lost')
      return out
    }
    const id = '11111111-1111-4111-8111-111111111111'
    await expect(s.tasks.start({ prompt: 'work' }, { id })).rejects.toThrow('start response lost')
    await expect(s.tasks.start({ prompt: 'work' }, { id })).resolves.toMatchObject({ id, turns: 1 })
    expect(s.fake.task(id).inbox).toHaveLength(1)
  })

  it('recovers the exact initial attachment envelope after admission but before runner launch', async () => {
    const s = setup()
    const id = '11111111-1111-4111-8111-111111111111'
    const input = { prompt: 'inspect these', attachments: [
      { name: 'image.png', type: 'image/png', data: b64('image contents') },
      { name: 'notes.txt', type: 'text/plain', data: b64('notes contents') },
    ] }
    s.fake.beforeLaunch(taskId => {
      s.fake.task(taskId).alive = false
      throw new Error('crash after directory rename, before launch')
    })
    await expect(s.tasks.start(input, { id })).rejects.toThrow('before launch')
    const state = s.fake.task(id)
    const admitted = state.published.get('000001')!
    expect(JSON.parse(admitted).attachments).toEqual([
      { path: `/home/caboose/Agents/${id}/attachments/image.png`, name: 'image.png', mimeType: 'image/png' },
      { path: `/home/caboose/Agents/${id}/attachments/notes.txt`, name: 'notes.txt', mimeType: 'text/plain' },
    ])
    const r = await restart(s)
    expect(r.tasks.list()[0]).toMatchObject({ id, status: 'running', turns: 1 })
    expect(state.published.get('000001')).toBe(admitted)
    expect(state.inbox).toEqual([admitted])
    expect(state.files.get(`/home/caboose/Agents/${id}/attachments/image.png`)).toBe('image contents')
    expect(state.files.get(`/home/caboose/Agents/${id}/attachments/notes.txt`)).toBe('notes contents')
    await expect(r.tasks.start(input, { id })).resolves.toMatchObject({ id, status: 'running', turns: 1 })
    await expect(r.tasks.reply(id, { prompt: 'later', operationId: 'later' })).resolves.toMatchObject({ queued: ['later'] })
    expect(state.inbox).toEqual([admitted])
  })

  it('recovers a prepared intent whose publish command never ran', async () => {
    const s = setup()
    const t = await s.tasks.start({ prompt: 'work' })
    await s.tasks.reply(t.id, { prompt: 'reply', operationId: 'one' })
    const run = s.fake.guest.run
    s.fake.guest.run = async (command, args, timeout) => {
      if (args.some(arg => arg.includes('echo launched'))) throw Error('transport failed before publish')
      return run(command, args, timeout)
    }
    await expect(s.tasks.sendNow(t.id)).rejects.toThrow('transport failed')
    expect(journal(s, t.id).intent.turn).toBe(2)
    s.fake.guest.run = run
    const r = await restart(s)
    expect(r.tasks.list()[0]).toMatchObject({ turns: 2, status: 'running' })
    expect(s.fake.task(t.id).inbox.filter(x => x !== 'cancel' && JSON.parse(x).turn === 2)).toHaveLength(1)
  })

  it.each([false, true])('retains a relaunched unclaimed turn instead of repeating its reply (Send Now=%s)', async sendNow => {
    const s = setup()
    const t = await s.tasks.start({ prompt: 'work' })
    s.fake.append(t.id, user(1)); s.fake.append(t.id, end(1, 'done'))
    await s.tasks.poll()
    s.fake.claimOnLaunch(false)
    await s.tasks.reply(t.id, { prompt: 'perform action once', operationId: 'op1' })
    const originalIntent = journal(s, t.id).intent
    expect(originalIntent).toMatchObject({ turn: 2, replies: ['op1'] })
    s.fake.task(t.id).alive = false
    s.fake.exit(t.id, '1', 'runner died before claim')
    await s.tasks.poll()
    expect(t).toMatchObject({ status: 'failed', turns: 2 })
    await s.tasks.reply(t.id, { prompt: 'later message', operationId: 'op2' })
    if (sendNow) await s.tasks.sendNow(t.id)
    expect(t).toMatchObject({ status: 'running', turns: 2, queued: ['later message'] })
    expect(journal(s, t.id).intent).toEqual(originalIntent)
    expect([...s.fake.task(t.id).published.values()].map(value => JSON.parse(value))).toMatchObject([
      { turn: 1, text: 'work' }, { turn: 2, text: 'perform action once' },
    ])
    // Only a proven end of the recovered turn permits a fresh batch containing op2 alone.
    s.fake.append(t.id, user(2, 'perform action once')); s.fake.append(t.id, end(2, 'done'))
    await s.tasks.poll()
    expect(t.turns).toBe(3)
    expect(JSON.parse(s.fake.task(t.id).published.get('000003')!)).toMatchObject({ turn: 3, text: 'later message' })
    expect(journal(s, t.id).intent).toMatchObject({ turn: 3, replies: ['op2'] })
  })

  it('does not republish an inbox after a lost delivery response', async () => {
    const s = setup()
    const t = await s.tasks.start({ prompt: 'work' })
    await s.tasks.reply(t.id, { prompt: 'reply' })
    const run = s.fake.guest.run
    s.fake.guest.run = async (command, args, timeout) => {
      const out = await run(command, args, timeout)
      if (args.some(arg => arg.includes('echo launched'))) throw Error('reply response lost')
      return out
    }
    await expect(s.tasks.sendNow(t.id)).rejects.toThrow('reply response lost')
    s.fake.guest.run = run
    const r = await restart(s)
    expect(r.tasks.list()[0]).toMatchObject({ turns: 2, status: 'running' })
    expect(r.tasks.list()[0]?.queued).toBeUndefined()
    expect(s.fake.task(t.id).inbox.filter(x => x !== 'cancel' && JSON.parse(x).turn === 2)).toHaveLength(1)
  })

  it.each(['partial-claim-before-unlink', 'claimed-before-unlink', 'claimed-after-unlink', 'old-runner-user', 'old-runner-unlink-gap', 'marker-before-inbox'])('reports %s as uncertain after interruption without replaying or discarding later replies', async point => {
    const s = setup()
    const t = await s.tasks.start({ prompt: 'work' })
    await s.tasks.reply(t.id, { prompt: 'first', operationId: 'one' })
    await s.tasks.sendNow(t.id)
    await s.tasks.reply(t.id, { prompt: 'later', operationId: 'two' })
    const state = s.fake.task(t.id)
    state.alive = false
    if (!point.endsWith('before-unlink')) state.inbox = state.inbox.filter(x => x === 'cancel' || JSON.parse(x).turn !== 2)
    if (point === 'partial-claim-before-unlink') state.receipts.set('000002', {})
    if (point.startsWith('old-') || point === 'marker-before-inbox') state.receipts.clear()
    if (point === 'old-runner-user') s.fake.append(t.id, user(2, 'first'))
    const r = await restart(s)
    expect(r.tasks.list()[0]).toMatchObject({ status: 'failed', delivery: { turn: 2, state: 'uncertain' }, queued: ['later'] })
    await expect(r.tasks.sendNow(t.id)).rejects.toBeInstanceOf(AgentConflictError)
    expect(state.published.get('000002')).toContain('first')
    expect(state.inbox.filter(x => x !== 'cancel' && JSON.parse(x).turn === 2)).toHaveLength(point.endsWith('before-unlink') ? 1 : 0)
    expect(journal(s, t.id).intent.uncertain).toBe(true)
  })

  it('reconciles an old runner terminal transcript without receipts and delivers later queued files once', async () => {
    const s = setup()
    const t = await s.tasks.start({ prompt: 'work' })
    await s.tasks.reply(t.id, { prompt: 'first' }); await s.tasks.sendNow(t.id)
    await s.tasks.reply(t.id, { prompt: 'later', attachments: [{ name: 'n.txt', data: b64('later file') }] })
    const state = s.fake.task(t.id)
    state.receipts.clear(); state.alive = false
    state.inbox = []
    s.fake.append(t.id, user(2, 'first')); s.fake.append(t.id, end(2, 'done'))
    const r = await restart(s)
    expect(r.tasks.list()[0]).toMatchObject({ status: 'running', turns: 3 })
    expect(JSON.parse(state.inbox.at(-1)!)).toMatchObject({ turn: 3, text: 'later', attachments: [{ name: 'n.txt' }] })
    expect(state.published.size).toBe(3)
  })

  it('uses a completed receipt when the transcript tail is unavailable and preserves queues on corrupt storage', async () => {
    const s = setup()
    const t = await s.tasks.start({ prompt: 'work' })
    await s.tasks.reply(t.id, { prompt: 'first' }); await s.tasks.sendNow(t.id)
    const state = s.fake.task(t.id)
    const receipt = state.receipts.get('000002')!
    state.receipts.set('000002', { ...receipt, state: 'completed', result: end(2, 'done') })
    state.alive = false; state.inbox = []
    const r = await restart(s)
    expect(r.tasks.list()[0]).toMatchObject({ status: 'succeeded', turns: 2, summary: 'done' })
    state.files.set('delivery.json', '{broken')
    r.tasks.pause()
    const broken = await restart(s)
    expect(broken.tasks.list()[0]?.status).toBe('failed')
    await expect(broken.tasks.reply(t.id, { prompt: 'x' })).rejects.toBeInstanceOf(AgentConflictError)
    expect(state.files.get('delivery.json')).toBe('{broken')
  })

  it('observes a runner loaded before upgrade without synthesizing a prompt, and retains newly admitted replies on interruption', async () => {
    const s = setup()
    const id = '11111111-1111-4111-8111-111111111111'
    s.fake.setListing([id, 'stand-in', '1790000500', '', '1', '0', b64('work'), '', 'auto', '2', '1', '', ''].join('\t'))
    await s.tasks.restore()
    expect(journal(s, id).intent).toMatchObject({ turn: 2, legacy: true })
    expect(s.fake.task(id).inbox).toEqual([])
    await s.tasks.reply(id, { prompt: 'queued', operationId: 'one' })
    s.fake.append(id, user(2)); s.fake.append(id, { type: 'turn_failed', turn: 2, message: 'Stopped.' })
    s.fake.task(id).alive = false
    await s.tasks.poll()
    expect(s.tasks.list()[0]).toMatchObject({ status: 'failed', delivery: { state: 'uncertain' }, queued: ['queued'] })
    expect(s.fake.task(id).inbox).toEqual([])
  })

  it('restores a live claim that precedes the turns-file update and holds its lease', async () => {
    const s = setup()
    const t = await s.tasks.start({ prompt: 'work' })
    await s.tasks.reply(t.id, { prompt: 'first' }); await s.tasks.sendNow(t.id)
    s.fake.append(t.id, user(1)); s.fake.append(t.id, end(1, 'done'))
    s.fake.setListing([t.id, 'stand-in', '1790000500', '', '1', String(s.fake.task(t.id).transcript.length), b64('work'), b64(line(end(1, 'done'))), 'auto', '1', '1', '', ''].join('\t'))
    const r = await restart(s)
    expect(r.tasks.list()[0]).toMatchObject({ status: 'running', turns: 2 })
    expect(r.release).not.toHaveBeenCalled()
    await r.tasks.reply(t.id, { prompt: 'later' })
    expect(r.tasks.list()[0]?.queued).toEqual(['later'])
    expect(s.fake.task(t.id).published.size).toBe(2)
  })

  it('holds an interrupted agent process uncertain instead of automatically draining admitted replies', async () => {
    const s = setup()
    const t = await s.tasks.start({ prompt: 'work' })
    await s.tasks.reply(t.id, { prompt: 'queued' })
    s.fake.append(t.id, user(1)); s.fake.append(t.id, { type: 'turn_failed', turn: 1, message: 'Connection lost', uncertain: true })
    await s.tasks.poll()
    expect(t).toMatchObject({ status: 'failed', delivery: { state: 'uncertain' }, queued: ['queued'] })
    expect(s.fake.task(t.id).published.size).toBe(1)
    expect(journal(s, t.id).intent.uncertain).toBe(true)
  })

  it('retains cancelled operation receipts across restart without reviving dropped replies', async () => {
    const s = setup()
    const t = await s.tasks.start({ prompt: 'work' })
    await s.tasks.reply(t.id, { prompt: 'drop', operationId: 'one' })
    await s.tasks.cancel(t.id)
    const r = await restart(s)
    await r.tasks.reply(t.id, { prompt: 'drop', operationId: 'one' })
    expect(r.tasks.list()[0]).toMatchObject({ status: 'cancelled', turns: 1 })
    expect(r.tasks.list()[0]?.queued).toBeUndefined()
    expect(journal(s, t.id).operations).toHaveLength(1)
    expect(s.fake.task(t.id).published.size).toBe(1)
  })


  it('keeps the computer leased while the next durable delivery write is delayed', async () => {
    const s = setup()
    const t = await s.tasks.start({ prompt: 'work' })
    await s.tasks.reply(t.id, { prompt: 'queued' })
    let unblock!: () => void, entered!: () => void
    const gate = new Promise<void>(resolve => { unblock = resolve })
    const writing = new Promise<void>(resolve => { entered = resolve })
    const run = s.fake.guest.run
    s.fake.guest.run = async (command, args, timeout) => {
      if (args.some(arg => arg.startsWith('// caboose delivery journal write'))) {
        const v = JSON.parse(Buffer.from(args.slice(9).join(''), 'base64').toString())
        if (v.intent?.turn === 2) { entered(); await gate }
      }
      return run(command, args, timeout)
    }
    s.fake.append(t.id, user(1)); s.fake.append(t.id, end(1, 'done'))
    const polling = s.tasks.poll()
    await writing
    expect(s.release).not.toHaveBeenCalled()
    unblock(); await polling
    expect(t).toMatchObject({ status: 'running', turns: 2 })
    expect(s.release).toHaveBeenCalledTimes(1)
  })

  it('never reuses a completed turn when the launch turns file is stale after a crash', async () => {
    const s = setup()
    const t = await s.tasks.start({ prompt: 'work' })
    await s.tasks.reply(t.id, { prompt: 'first' }); await s.tasks.sendNow(t.id)
    s.fake.append(t.id, user(2)); s.fake.append(t.id, end(2, 'done'))
    await s.tasks.poll()
    expect(journal(s, t.id)).toMatchObject({ turns: 2 })
    expect(journal(s, t.id).intent).toBeUndefined()
    s.fake.setListing([t.id, 'stand-in', '1790000500', '0', '0', String(s.fake.task(t.id).transcript.length), b64('work'), b64(line(end(2, 'done'))), 'auto', '1', '1', '', ''].join('\t'))
    const r = await restart(s)
    expect(r.tasks.list()[0]).toMatchObject({ status: 'succeeded', turns: 2 })
    await r.tasks.reply(t.id, { prompt: 'next', operationId: 'next' })
    expect(r.tasks.list()[0]?.turns).toBe(3)
    expect(JSON.parse(s.fake.task(t.id).inbox.at(-1)!)).toMatchObject({ turn: 3, text: 'next' })
  })

})


describe('persistent profile tasks', () => {
  const profile = { id: 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee', instructions: 'Remember that reports use Toronto time.', workspace: '/home/caboose/AgentWorkspaces/aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee' }
  it('stages identity outside the owner prompt and restores it with the shared workspace', async () => {
    const s = setup()
    const id = '11111111-2222-3333-4444-555555555555'
    const input = { prompt: 'Write the report', agent: 'codex', profileId: profile.id }
    try {
      const task = await s.tasks.start(input, { id, profile })
      expect(task.profileId).toBe(profile.id)
      const state = s.fake.task(id)
      expect(JSON.parse(state.files.get('task.json')!)).toMatchObject({ cwd: profile.workspace, profileId: profile.id })
      expect(state.files.get(`/home/caboose/Agents/${id}/profile-instructions.txt`)).toBe(profile.instructions)
      expect(JSON.parse(state.inbox[0]!).text).toBe('Write the report')
      const restored = new AgentTasks(() => s.fake.guest, () => {}, () => () => {}, { resolver: resolver(), pollMs: 60_000 })
      try {
        await restored.restore()
        expect(restored.list().find(t => t.id === id)?.profileId).toBe(profile.id)
        await expect(restored.start(input, { id, profile })).resolves.toMatchObject({ id, profileId: profile.id })
        await expect(restored.start(input, { id, profile: { ...profile, instructions: 'Different' } })).rejects.toThrow(AgentConflictError)
      } finally { restored.pause() }
    } finally { s.tasks.pause() }
  })
  it('binds profile tools before admission and does not enable them without a journal', async () => {
    const fake = fakeGuest()
    const bindTask = vi.fn(async () => {})
    const journal = { bindTask } as unknown as AgentToolJournal
    const tasks = new AgentTasks(() => fake.guest, () => {}, () => () => {}, { resolver: resolver(), pollMs: 60_000, toolJournal: async () => journal })
    try {
      fake.beforeLaunch(() => { expect(bindTask).toHaveBeenCalledTimes(1) })
      const result = await tasks.start({ prompt: 'hello', profileId: profile.id }, { profile })
      expect(bindTask).toHaveBeenCalledWith(result.id, profile.id)
      expect(JSON.parse(fake.task(result.id).files.get('task.json')!).agentTools).toBe(true)
      fake.beforeLaunch(() => {})
      const ordinary = await tasks.start({ prompt: 'hello' })
      expect(JSON.parse(fake.task(ordinary.id).files.get('task.json')!).agentTools).toBeUndefined()
      expect(bindTask).toHaveBeenCalledTimes(1)
    } finally { tasks.pause() }
  })
  it('drains an in-flight mailbox poll after pausing', async () => {
    const fake = fakeGuest()
    let release!: () => void
    const waiting = new Promise<void>(resolve => { release = resolve })
    let calls = 0
    const journal = { bindTask: vi.fn(async () => {}) } as unknown as AgentToolJournal
    const tasks = new AgentTasks(() => fake.guest, () => {}, () => () => {}, {
      resolver: resolver(), pollMs: 10, toolJournal: async () => { if (++calls > 1) await waiting; return calls === 1 ? journal : null },
    })
    try {
      await tasks.start({ prompt: 'hello', profileId: profile.id }, { profile })
      await vi.waitFor(() => expect(calls).toBeGreaterThan(1))
      tasks.pause()
      let drained = false
      const done = tasks.drainToolWork().then(() => { drained = true })
      await Promise.resolve()
      expect(drained).toBe(false)
      release()
      await done
      expect(drained).toBe(true)
    } finally { release(); tasks.pause() }
  })
  it('rejects unresolved profiles and arbitrary workspace paths before guest writes', async () => {
    const s = setup()
    try {
      await expect(s.tasks.start({ prompt: 'Hi', profileId: profile.id })).rejects.toThrow('Resolve')
      await expect(s.tasks.start({ prompt: 'Hi' }, { profile: { ...profile, workspace: '/etc' } })).rejects.toThrow('Invalid persistent')
      expect(s.fake.calls).toHaveLength(0)
    } finally { s.tasks.pause() }
  })
})
