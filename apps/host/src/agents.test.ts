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

  it('rejects bad input and a parked computer', async () => {
    const tasks = new AgentTasks(() => undefined, () => {}, () => () => {}, 60_000)
    await expect(tasks.start({ prompt: '', agent: 'claude' })).rejects.toBeInstanceOf(AgentInputError)
    await expect(tasks.start({ prompt: 'x', agent: 'gpt' })).rejects.toBeInstanceOf(AgentInputError)
    await expect(tasks.start({ prompt: 'x', agent: 'claude' })).rejects.toThrow('computer is not running')
  })
})
