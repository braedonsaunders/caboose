import { describe, expect, it, vi } from 'vitest'
import { AgentInputError, AgentTasks, interpretLine, launchScript, type AgentEvent, type AgentGuest } from './agents.js'

describe('interpretLine', () => {
  it('reads Claude Code stream-json', () => {
    const assistant = JSON.stringify({ type: 'assistant', message: { content: [
      { type: 'text', text: 'Cloning the repo.' },
      { type: 'tool_use', name: 'Bash', input: { command: 'git clone https://example.com/x.git' } },
    ] } })
    expect(interpretLine(assistant).outputs).toEqual([
      { kind: 'text', text: 'Cloning the repo.' },
      { kind: 'tool', text: 'Bash: git clone https://example.com/x.git' },
    ])
    expect(interpretLine(JSON.stringify({ type: 'result', subtype: 'success', is_error: false, result: 'All tests pass.' })).result)
      .toEqual({ ok: true, summary: 'All tests pass.' })
    expect(interpretLine(JSON.stringify({ type: 'result', subtype: 'error_max_turns', is_error: true })).result?.ok).toBe(false)
  })

  it('reads Codex exec --json', () => {
    expect(interpretLine(JSON.stringify({ type: 'item.completed', item: { type: 'agent_message', text: 'Done refactoring.' } })).outputs)
      .toEqual([{ kind: 'text', text: 'Done refactoring.' }])
    expect(interpretLine(JSON.stringify({ type: 'item.completed', item: { type: 'command_execution', command: 'pnpm test' } })).outputs)
      .toEqual([{ kind: 'tool', text: '$ pnpm test' }])
    expect(interpretLine(JSON.stringify({ type: 'turn.failed', error: { message: 'rate limited' } })).result)
      .toEqual({ ok: false, summary: 'rate limited' })
  })

  it('ignores lines that are not JSON', () => {
    expect(interpretLine('not json')).toEqual({ outputs: [] })
  })
})

describe('launchScript', () => {
  it('runs each CLI detached on the agent seat with its transcript on disk', () => {
    const claude = launchScript('claude')
    expect(claude).toContain('DISPLAY=:101')
    expect(claude).toContain('--output-format stream-json')
    expect(claude).toContain('mcp__caboose-desktop')
    expect(claude).toContain('> transcript.jsonl')
    expect(launchScript('codex')).toContain('codex exec --json')
  })
})

/** A guest whose transcript file grows as the test appends lines. */
function fakeGuest() {
  let transcript = ''
  let exitCode = ''
  let stderr = ''
  const calls: string[][] = []
  const guest: AgentGuest = {
    async run(command, args) {
      calls.push([command, ...args])
      const script = args.find(arg => arg.includes('tail -c')) ? 'tail' : ''
      if (script === 'tail') {
        const offset = Number(args[args.length - 1])
        return `${transcript.slice(offset)}\n__CABOOSE__${exitCode}:${stderr}`
      }
      return ''
    },
  }
  return {
    guest, calls,
    append: (line: object) => { transcript += JSON.stringify(line) + '\n' },
    exit: (code: string, message = '') => { exitCode = code; stderr = message },
  }
}

describe('AgentTasks', () => {
  it('starts a task, streams its output, and releases the lease when it finishes', async () => {
    const fake = fakeGuest()
    const events: AgentEvent[] = []
    const release = vi.fn()
    const tasks = new AgentTasks(() => fake.guest, event => events.push(event), () => release, 60_000)
    const task = await tasks.start({ prompt: 'Run the tests', agent: 'claude' })
    expect(task.status).toBe('running')
    expect(fake.calls.some(call => call.join(' ').includes('caboose-xpra-agent.service'))).toBe(true)
    fake.append({ type: 'assistant', message: { content: [{ type: 'text', text: 'Running pnpm test.' }] } })
    await tasks.poll()
    fake.append({ type: 'result', subtype: 'success', is_error: false, result: '42 tests passed.' })
    await tasks.poll()
    expect(events.map(event => event.type)).toEqual(['agent.task.started', 'agent.task.output', 'agent.task.finished'])
    expect(tasks.list()[0]).toMatchObject({ status: 'succeeded', summary: '42 tests passed.' })
    expect(release).toHaveBeenCalledTimes(1)
    tasks.pause()
  })

  it('reports a signed-out CLI with a way to fix it', async () => {
    const fake = fakeGuest()
    const events: AgentEvent[] = []
    const tasks = new AgentTasks(() => fake.guest, event => events.push(event), () => () => {}, 60_000)
    await tasks.start({ prompt: 'hello', agent: 'codex' })
    fake.exit('1', 'Error: Not logged in. Please run codex login')
    await tasks.poll()
    const finished = events.find(event => event.type === 'agent.task.finished')
    expect(finished).toMatchObject({ status: 'failed' })
    expect((finished as { summary: string }).summary).toContain('signed out')
    tasks.pause()
  })

  it('cancels a running task', async () => {
    const fake = fakeGuest()
    const tasks = new AgentTasks(() => fake.guest, () => {}, () => () => {}, 60_000)
    const task = await tasks.start({ prompt: 'long job', agent: 'claude' })
    expect(await tasks.cancel(task.id)).toBe(true)
    expect(tasks.list()[0]?.status).toBe('cancelled')
    expect(await tasks.cancel(task.id)).toBe(false)
    tasks.pause()
  })

  it('pauses a task for take-over and continues it on hand-back', async () => {
    const fake = fakeGuest()
    const events: AgentEvent[] = []
    const tasks = new AgentTasks(() => fake.guest, event => events.push(event), () => () => {}, 60_000)
    const task = await tasks.start({ prompt: 'fill the form', agent: 'claude' })
    expect(await tasks.resumeTask(task.id)).toBe(false)
    expect(await tasks.pauseTask(task.id)).toBe(true)
    expect(fake.calls.at(-1)?.join(' ')).toContain('kill -STOP -- -"$pid"')
    expect(tasks.list()[0]?.status).toBe('paused')
    expect(await tasks.resumeTask(task.id)).toBe(true)
    expect(fake.calls.at(-1)?.join(' ')).toContain('kill -CONT')
    await tasks.pauseTask(task.id)
    expect(await tasks.cancel(task.id)).toBe(true)
    expect(fake.calls.at(-1)?.join(' ')).toMatch(/kill -TERM.*kill -CONT/)
    expect(events.map(event => event.type)).toEqual(['agent.task.started', 'agent.task.paused', 'agent.task.resumed',
      'agent.task.paused', 'agent.task.finished'])
    tasks.pause()
  })

  it('restores tasks from the guest after a host restart', async () => {
    const b64 = (text: string) => Buffer.from(text).toString('base64')
    const running = '11111111-1111-4111-8111-111111111111'
    const done = '22222222-2222-4222-8222-222222222222'
    const orphan = '33333333-3333-4333-8333-333333333333'
    const listing = [
      [running, 'codex', '1790000300', '', '1', '512', b64('keep going'), b64('{}')],
      [done, 'claude', '1790000200', '0', '0', '900', b64('run tests'),
        b64(JSON.stringify({ type: 'result', subtype: 'success', is_error: false, result: 'All green.' }))],
      [orphan, 'claude', '1790000100', '', '0', '10', b64('lost'), ''],
    ].map(fields => fields.join('\t')).join('\n')
    const guest: AgentGuest = { run: async (_command, args) => args.some(arg => arg.includes('ls -1t')) ? listing : '' }
    const events: AgentEvent[] = []
    const release = vi.fn()
    const acquire = vi.fn(() => release)
    const tasks = new AgentTasks(() => guest, event => events.push(event), acquire, 60_000)
    await tasks.restore()
    await tasks.restore()
    expect(tasks.list().map(task => [task.id, task.status, task.agent])).toEqual([
      [running, 'running', 'codex'], [done, 'succeeded', 'claude'], [orphan, 'failed', 'claude'],
    ])
    expect(tasks.list()[0]?.prompt).toBe('keep going')
    expect(tasks.list()[1]?.summary).toBe('All green.')
    expect(acquire).toHaveBeenCalledTimes(1)
    expect(events).toEqual([])
    tasks.pause()
  })

  it('rejects bad input and a parked computer', async () => {
    const tasks = new AgentTasks(() => undefined, () => {}, () => () => {}, 60_000)
    await expect(tasks.start({ prompt: '', agent: 'claude' })).rejects.toBeInstanceOf(AgentInputError)
    await expect(tasks.start({ prompt: 'x', agent: 'gpt' })).rejects.toBeInstanceOf(AgentInputError)
    await expect(tasks.start({ prompt: 'x', agent: 'claude' })).rejects.toThrow('computer is not running')
  })

  it('releases running and paused task leases after a cold restart', async () => {
    const fake = fakeGuest()
    const release = vi.fn()
    const tasks = new AgentTasks(() => fake.guest, () => {}, () => release, 60000)
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
