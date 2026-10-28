import { describe, expect, it, vi } from 'vitest'
import {
  AgentConflictError, AgentInputError, AgentNotFoundError, AgentTasks, LEGACY_SUMMARY, describeRequest, interpretLine, parsePoll, parseRequest,
  readAttachments, transcriptEntry, type AgentEvent, type AgentGuest, type AgentResolver,
} from './agents.js'
import type { AgentLaunch } from './registry.js'

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

interface FakeTask { draft?: object; transcript: Buffer; exitCode: string; stderr: string; approvals: Map<string, { json: string; decision?: string }>; files: Map<string, string>; inbox: string[] }

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
  let listing = ''
  const task = (id: string): FakeTask => {
    let entry = tasks.get(id)
    if (!entry) tasks.set(id, entry = { transcript: Buffer.alloc(0), exitCode: '', stderr: '', approvals: new Map(), files: new Map(), inbox: [] })
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
      if (script.includes('ls -1t')) return listing
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
        state.inbox.push(rest[6]!)
      }
      if (script.includes('echo launched')) {
        const state = task(idOf(rest[0]!))
        state.inbox.push(rest[1]!)
        state.exitCode = ''
        return 'delivered\n'
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
    setListing: (value: string) => { listing = value },
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

function setup(options: { defaultAgent?: string | null; craftServers?: () => Promise<Array<{ name: string; command: string; args: string[]; env: Array<{ name: string; value: string }> }>> } = {}) {
  const fake = fakeGuest()
  const events: AgentEvent[] = []
  const release = vi.fn()
  const acquire = vi.fn(() => release)
  const agents = resolver(options.defaultAgent === undefined ? 'stand-in' : options.defaultAgent)
  const tasks = new AgentTasks(() => fake.guest, event => events.push(event), acquire, { resolver: agents, pollMs: 60_000, idleMs: 120_000, craftServers: options.craftServers })
  return { fake, events, release, acquire, agents, tasks }
}

describe('AgentTasks', () => {
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
    expect(JSON.parse(state.inbox[0]!)).toEqual({ type: 'prompt', turn: 1, text: 'Run the tests' })
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
    expect(tasks.list().find(task => task.id === failed.id)).toMatchObject({ status: 'failed', summary: 'The agent exited with code 3.' })
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
    const launch = fake.calls.at(-1)!
    expect(fake.scriptOf(launch)).toContain('echo launched')
    expect(launch.slice(8)).toEqual([`/home/caboose/Agents/${task.id}`, JSON.stringify({ type: 'prompt', turn: 2, text: 'shorter' }), '2', '000002'])
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
    expect(JSON.parse(fake.task(task.id).inbox.at(-1)!)).toEqual({ type: 'prompt', turn: 2, text: 'how is it going?\n\nskip the PDFs' })
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
    expect(JSON.parse(fake.task(signedOut.id).inbox.at(-1)!)).toEqual({ type: 'prompt', turn: 2, text: 'd\n\ne' })
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
    expect(JSON.parse(fake.task(task.id).inbox[0]!)).toEqual({ type: 'prompt', turn: 1, text: 'What is in this picture?', attachments: [
      { path: `${dir}/attachments/photo.png`, name: 'photo.png', mimeType: 'image/png' },
      { path: `${dir}/attachments/notes.txt`, name: 'notes.txt' },
    ] })
    expect(tasks.list()[0]?.prompt).toBe('What is in this picture?')
  })

  it('removes the task directory when the start fails', async () => {
    const fake = fakeGuest()
    const guest: AgentGuest = { run: async (command, args, timeout) => {
      if (args[5]?.includes('setsid')) throw new Error('caboose-agentd is not installed in this computer')
      return fake.guest.run(command, args, timeout)
    } }
    const tasks = new AgentTasks(() => guest, () => {}, () => () => {}, { resolver: resolver(), pollMs: 60_000 })
    await expect(tasks.start({ prompt: 'x' })).rejects.toBeInstanceOf(AgentConflictError)
    await expect(tasks.start({ prompt: 'x' })).rejects.toThrow('This computer has no agent runner')
    expect(fake.scriptOf(fake.calls.at(-1))).toContain('rm -rf')
    expect(tasks.list()).toEqual([])
  })

  it('cancels a running turn through the runner', async () => {
    const { fake, events, tasks } = setup()
    const task = await tasks.start({ prompt: 'long job' })
    expect(await tasks.cancel(task.id)).toBe(true)
    expect(fake.task(task.id).inbox.at(-1)).toBe('cancel')
    expect(fake.scriptOf(fake.calls.at(-1))).toContain('kill -CONT')
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
    expect(fake.calls.at(-1)!.slice(8)).toEqual([`/home/caboose/Agents/${done}`, JSON.stringify({ type: 'prompt', turn: 4, text: 'and lint' }), '4', '000004'])
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
