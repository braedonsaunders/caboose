import { describe, expect, it, vi } from 'vitest'
import {
  AgentConflictError, AgentInputError, AgentNotFoundError, AgentTasks, describeRequest, interpretLine, launchScript, parsePoll,
  readAttachments, type AgentEvent, type AgentGuest,
} from './agents.js'

const b64 = (text: string | Buffer) => Buffer.from(text).toString('base64')

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

  it('finds the conversation id a reply resumes, and only a safe one', () => {
    expect(interpretLine(JSON.stringify({ type: 'system', subtype: 'init', session_id: 'c237ef1f-3019-47c0-b325-b54d7cb4781d', tools: [] })).session)
      .toBe('c237ef1f-3019-47c0-b325-b54d7cb4781d')
    expect(interpretLine(JSON.stringify({ type: 'thread.started', thread_id: '01a180b6-72e3-7d31-abd8-e6988a958814' })).session)
      .toBe('01a180b6-72e3-7d31-abd8-e6988a958814')
    expect(interpretLine(JSON.stringify({ type: 'system', subtype: 'init', session_id: '$(reboot)' })).session).toBeUndefined()
    expect(interpretLine(JSON.stringify({ type: 'thread.started', thread_id: '../../etc' })).session).toBeUndefined()
  })

  it('ignores lines that are not JSON', () => {
    expect(interpretLine('not json')).toEqual({ outputs: [] })
  })
})

describe('launchScript', () => {
  it('runs each CLI detached on the agent seat with its transcript on disk', () => {
    const claude = launchScript('claude')
    expect(claude).toContain('DISPLAY=:101')
    expect(claude).toContain('CABOOSE_TASK_DIR="$PWD"')
    expect(claude).toContain('--output-format stream-json')
    expect(claude).toContain('--permission-mode acceptEdits')
    expect(claude).toContain('mcp__caboose-desktop')
    expect(claude).toContain('>> transcript.jsonl')
    expect(claude).not.toContain('--resume')
    expect(launchScript('codex')).toContain('codex exec --json --skip-git-repo-check --dangerously-bypass-approvals-and-sandbox "$(cat turn.txt)"')
  })

  it('asks through the approve tool instead of pre-approving tools', () => {
    const ask = launchScript('claude', { approvals: 'ask' })
    expect(ask).toContain('--permission-prompt-tool mcp__caboose-desktop__approve')
    expect(ask).not.toContain('--allowedTools')
    expect(ask).not.toContain('acceptEdits')
  })

  it('resumes the recorded conversation', () => {
    expect(launchScript('claude', { resume: true })).toContain('claude -p "$(cat turn.txt)" --resume "$(cat session)"')
    expect(launchScript('codex', { resume: true }))
      .toContain('codex exec resume --json --skip-git-repo-check --dangerously-bypass-approvals-and-sandbox "$(cat session)" "$(cat turn.txt)"')
  })
})

describe('approval requests', () => {
  it('describes what the agent wants to do in one line', () => {
    expect(describeRequest('Bash', { command: 'rm -rf build', description: 'clean' })).toBe('Bash: rm -rf build')
    expect(describeRequest('Write', { file_path: '/home/caboose/a.txt', content: 'x' })).toBe('Write: /home/caboose/a.txt')
    expect(describeRequest('mcp__caboose-desktop__click', { x: 1, y: 2 })).toBe('Desktop click: {"x":1,"y":2}')
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

interface FakeTask { transcript: Buffer; exitCode: string; stderr: string; approvals: Map<string, { json: string; decision?: string }>; files: Map<string, string> }

/**
 * A guest that answers the host's scripts from in-memory task directories: the batched
 * poll, decisions, file writes and launches. Tests append transcript lines as the CLI would.
 */
function fakeGuest() {
  const tasks = new Map<string, FakeTask>()
  const calls: string[][] = []
  let polls = 0
  let listing = ''
  const task = (id: string): FakeTask => {
    let entry = tasks.get(id)
    if (!entry) tasks.set(id, entry = { transcript: Buffer.alloc(0), exitCode: '', stderr: '', approvals: new Map(), files: new Map() })
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
          for (const [requestId, request] of state.approvals) {
            if (request.decision === undefined) out += `A\t${id}\t${requestId}\t${b64(request.json)}\n`
          }
        }
        return out
      }
      if (script.includes('ls -1t')) return listing
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
      if (script.includes('rm -f exit-code')) task(idOf(rest[0]!)).exitCode = ''
      return ''
    },
  }
  return {
    guest, calls, task,
    get polls() { return polls },
    setListing: (value: string) => { listing = value },
    append: (id: string, line: object) => { const state = task(id); state.transcript = Buffer.concat([state.transcript, Buffer.from(JSON.stringify(line) + '\n')]) },
    exit: (id: string, code: string, message = '') => { task(id).exitCode = code; task(id).stderr = message },
    request: (id: string, requestId: string, value: object) => { task(id).approvals.set(requestId, { json: JSON.stringify(value) }) },
    scriptOf: (call: string[] | undefined) => call?.[0] === '/usr/sbin/runuser' ? call[6] : call?.[2],
  }
}

const REQUEST = '6f1c2a8e-1d2b-4c3d-8e4f-5a6b7c8d9e0f'
const init = (session: string) => ({ type: 'system', subtype: 'init', session_id: session, tools: [] })
const result = (text: string) => ({ type: 'result', subtype: 'success', is_error: false, result: text })

describe('AgentTasks', () => {
  it('starts a task, streams its output, and releases the lease when it finishes', async () => {
    const fake = fakeGuest()
    const events: AgentEvent[] = []
    const release = vi.fn()
    const tasks = new AgentTasks(() => fake.guest, event => events.push(event), () => release, 60_000)
    const task = await tasks.start({ prompt: 'Run the tests', agent: 'claude' })
    expect(task).toMatchObject({ status: 'running', turns: 1, approvals: 'auto' })
    expect(task.attachments).toBeUndefined()
    expect(fake.calls.some(call => call.join(' ').includes('caboose-xpra-agent.service'))).toBe(true)
    fake.append(task.id, { type: 'assistant', message: { content: [{ type: 'text', text: 'Running pnpm test.' }] } })
    await tasks.poll()
    fake.append(task.id, result('42 tests passed.'))
    await tasks.poll()
    expect(events.map(event => event.type)).toEqual(['agent.task.started', 'agent.task.output', 'agent.task.finished'])
    expect(tasks.list()[0]).toMatchObject({ status: 'succeeded', summary: '42 tests passed.' })
    expect(release).toHaveBeenCalledTimes(1)
    tasks.pause()
  })

  it('starts the seat through the driver when it has its own way', async () => {
    const fake = fakeGuest()
    const ensureSeat = vi.fn(async () => {})
    const tasks = new AgentTasks(() => fake.guest, () => {}, () => () => {}, 60_000, ensureSeat)
    await tasks.start({ prompt: 'hi' })
    expect(ensureSeat).toHaveBeenCalledTimes(1)
    expect(fake.calls.some(call => call.join(' ').includes('systemctl'))).toBe(false)
    tasks.pause()
  })

  it('polls every live task with one guest command per tick, and does nothing when idle', async () => {
    const fake = fakeGuest()
    const events: AgentEvent[] = []
    const tasks = new AgentTasks(() => fake.guest, event => events.push(event), () => () => {}, 60_000)
    const a = await tasks.start({ prompt: 'a' })
    const b = await tasks.start({ prompt: 'b', agent: 'codex' })
    fake.append(a.id, { type: 'assistant', message: { content: [{ type: 'text', text: 'from a' }] } })
    fake.append(b.id, { type: 'item.completed', item: { type: 'agent_message', text: 'from b' } })
    const before = fake.calls.length
    await tasks.poll()
    expect(fake.calls.length - before).toBe(1)
    expect(fake.polls).toBe(1)
    expect(events.filter(event => event.type === 'agent.task.output').map(event => (event as { text: string }).text).sort())
      .toEqual(['from a', 'from b'])
    fake.exit(a.id, '0')
    fake.exit(b.id, '0')
    await tasks.poll()
    expect(tasks.list().every(task => task.status === 'succeeded')).toBe(true)
    const idle = fake.calls.length
    await tasks.poll()
    expect(fake.calls.length).toBe(idle)
  })

  it('keeps byte offsets exact across multi-byte text and waits for the whole transcript before finishing', async () => {
    const fake = fakeGuest()
    const events: AgentEvent[] = []
    const tasks = new AgentTasks(() => fake.guest, event => events.push(event), () => () => {}, 60_000)
    const task = await tasks.start({ prompt: 'big' })
    // ~1.5 MiB of three-byte characters: more than one tick's budget, split mid-character.
    const text = '✓'.repeat(500_000)
    fake.append(task.id, { type: 'assistant', message: { content: [{ type: 'text', text }] } })
    fake.append(task.id, { type: 'assistant', message: { content: [{ type: 'text', text: 'tail ✓' }] } })
    fake.exit(task.id, '0')
    await tasks.poll()
    expect(tasks.list()[0]?.status).toBe('running')
    await tasks.poll()
    const outputs = events.filter(event => event.type === 'agent.task.output').map(event => (event as { text: string }).text)
    expect(outputs).toEqual([text, 'tail ✓'])
    expect(tasks.list()[0]).toMatchObject({ status: 'succeeded', summary: 'tail ✓' })
  })

  it('reports a signed-out CLI with a way to fix it', async () => {
    const fake = fakeGuest()
    const events: AgentEvent[] = []
    const tasks = new AgentTasks(() => fake.guest, event => events.push(event), () => () => {}, 60_000)
    const task = await tasks.start({ prompt: 'hello', agent: 'codex' })
    fake.exit(task.id, '1', 'Error: Not logged in. Please run codex login')
    await tasks.poll()
    const finished = events.find(event => event.type === 'agent.task.finished')
    expect(finished).toMatchObject({ status: 'failed' })
    expect((finished as { summary: string }).summary).toContain('signed out')
    tasks.pause()
  })

  it('continues a finished conversation and appends the turn to the same transcript', async () => {
    const fake = fakeGuest()
    const events: AgentEvent[] = []
    const acquire = vi.fn(() => () => {})
    const tasks = new AgentTasks(() => fake.guest, event => events.push(event), acquire, 60_000)
    const task = await tasks.start({ prompt: 'write a poem' })
    await expect(tasks.reply(task.id, { prompt: 'shorter' })).rejects.toBeInstanceOf(AgentConflictError)
    fake.append(task.id, init('c237ef1f-3019-47c0-b325-b54d7cb4781d'))
    fake.append(task.id, result('A long poem.'))
    await tasks.poll()
    // The id is kept beside the transcript for a host restart.
    expect(fake.calls.some(call => fake.scriptOf(call)?.includes('> "$1/session"') && call.includes('c237ef1f-3019-47c0-b325-b54d7cb4781d'))).toBe(true)
    fake.exit(task.id, '0')
    const replied = await tasks.reply(task.id, { prompt: '  shorter  ' })
    expect(replied).toMatchObject({ id: task.id, status: 'running', turns: 2, prompt: 'write a poem' })
    expect(replied.summary).toBeUndefined()
    const launch = fake.calls.at(-1)!
    expect(fake.scriptOf(launch)).toContain('--resume "$(cat session)"')
    expect(fake.scriptOf(launch)).toContain('rm -f exit-code')
    expect(launch.slice(8)).toEqual([`/home/caboose/Agents/${task.id}`, 'shorter', 'c237ef1f-3019-47c0-b325-b54d7cb4781d', '2'])
    expect(events.at(-1)).toEqual({ type: 'agent.task.replied', id: task.id, prompt: 'shorter', turn: 2 })
    expect(acquire).toHaveBeenCalledTimes(2)
    fake.append(task.id, init('c237ef1f-3019-47c0-b325-b54d7cb4781d'))
    fake.append(task.id, result('A short poem.'))
    await tasks.poll()
    expect(tasks.list()[0]).toMatchObject({ status: 'succeeded', summary: 'A short poem.', turns: 2 })
    expect(events.filter(event => event.type === 'agent.task.finished')).toHaveLength(2)
  })

  it('resumes a Codex thread', async () => {
    const fake = fakeGuest()
    const tasks = new AgentTasks(() => fake.guest, () => {}, () => () => {}, 60_000)
    const task = await tasks.start({ prompt: 'fix it', agent: 'codex' })
    fake.append(task.id, { type: 'thread.started', thread_id: '01a180b6-72e3-7d31-abd8-e6988a958814' })
    fake.append(task.id, { type: 'turn.failed', error: { message: 'stuck' } })
    await tasks.poll()
    await tasks.reply(task.id, { prompt: 'try again' })
    expect(fake.scriptOf(fake.calls.at(-1))).toContain('codex exec resume')
    expect(fake.calls.at(-1)).toContain('01a180b6-72e3-7d31-abd8-e6988a958814')
    tasks.pause()
  })

  it('refuses replies it cannot honour', async () => {
    const fake = fakeGuest()
    const tasks = new AgentTasks(() => fake.guest, () => {}, () => () => {}, 60_000)
    await expect(tasks.reply('11111111-1111-4111-8111-111111111111', { prompt: 'x' })).rejects.toBeInstanceOf(AgentNotFoundError)
    await expect(tasks.reply('../../etc', { prompt: 'x' })).rejects.toBeInstanceOf(AgentNotFoundError)
    const task = await tasks.start({ prompt: 'x' })
    await tasks.cancel(task.id)
    await expect(tasks.reply(task.id, { prompt: '' })).rejects.toBeInstanceOf(AgentInputError)
    // Cancelled before the CLI reported a session: there is nothing to continue.
    await expect(tasks.reply(task.id, { prompt: 'more' })).rejects.toThrow('no conversation')
  })

  it('asks the owner before acting and passes the answer back', async () => {
    const fake = fakeGuest()
    const events: AgentEvent[] = []
    const tasks = new AgentTasks(() => fake.guest, event => events.push(event), () => () => {}, 60_000)
    await expect(tasks.start({ prompt: 'x', agent: 'codex', approvals: 'ask' })).rejects.toThrow('Codex cannot ask')
    await expect(tasks.start({ prompt: 'x', approvals: 'sometimes' })).rejects.toBeInstanceOf(AgentInputError)
    const task = await tasks.start({ prompt: 'clean up', approvals: 'ask' })
    expect(task.approvals).toBe('ask')
    expect(fake.scriptOf(fake.calls.at(-1))).toContain('--permission-prompt-tool mcp__caboose-desktop__approve')
    fake.request(task.id, REQUEST, { tool: 'Bash', input: { command: 'rm -rf build' }, requestedAt: '2026-10-28T00:00:00.000Z' })
    fake.request(task.id, 'not-a-uuid', { tool: 'Bash', input: {} })
    await tasks.poll()
    await tasks.poll()
    const request = { id: REQUEST, tool: 'Bash', summary: 'Bash: rm -rf build' }
    expect(events.filter(event => event.type === 'agent.task.approval')).toEqual([{ type: 'agent.task.approval', id: task.id, request }])
    expect(tasks.list()[0]?.pendingApproval).toEqual(request)
    await expect(tasks.resolveApproval(task.id, '../x', { allow: true })).rejects.toBeInstanceOf(AgentInputError)
    await expect(tasks.resolveApproval(task.id, REQUEST, { allow: 'yes' })).rejects.toBeInstanceOf(AgentInputError)
    expect(await tasks.resolveApproval(task.id, REQUEST, { allow: false, message: 'Not the build dir.' })).toBe(true)
    expect(JSON.parse(fake.task(task.id).approvals.get(REQUEST)!.decision!)).toEqual({ allow: false, message: 'Not the build dir.' })
    expect(events.at(-1)).toEqual({ type: 'agent.task.approval.resolved', id: task.id, requestId: REQUEST, allow: false })
    expect(tasks.list()[0]?.pendingApproval).toBeUndefined()
    expect(await tasks.resolveApproval(task.id, REQUEST, { allow: true })).toBe(false)
    await tasks.poll()
    expect(events.filter(event => event.type === 'agent.task.approval')).toHaveLength(1)
    tasks.pause()
  })

  it('writes attachments into the task and names them in the prompt', async () => {
    const fake = fakeGuest()
    const tasks = new AgentTasks(() => fake.guest, () => {}, () => () => {}, 60_000)
    const png = Buffer.from([0x89, 0x50, 0x4e, 0x47, 0, 255])
    const task = await tasks.start({ prompt: 'What is in this picture?', attachments: [
      { name: 'photo.png', type: 'image/png', data: png.toString('base64') },
      { name: 'a/../notes.txt', type: 'text/plain', data: b64('notes') },
    ] })
    const dir = `/home/caboose/Agents/${task.id}`
    expect(task.attachments).toEqual([`${dir}/attachments/photo.png`, `${dir}/attachments/notes.txt`])
    expect(fake.task(task.id).files.get(`${dir}/attachments/photo.png`)).toBe(png.toString('latin1'))
    expect(fake.task(task.id).files.get(`${dir}/attachments/notes.txt`)).toBe('notes')
    const setup = fake.calls.find(call => fake.scriptOf(call)?.includes('turn.txt'))!
    expect(setup.slice(8, 11)).toEqual([dir, 'What is in this picture?',
      `What is in this picture?\n\nAttached files:\n- ${dir}/attachments/photo.png\n- ${dir}/attachments/notes.txt`])
    expect(tasks.list()[0]?.prompt).toBe('What is in this picture?')
    tasks.pause()
  })

  it('removes the task directory when the launch fails', async () => {
    const fake = fakeGuest()
    const run = fake.guest.run
    const guest: AgentGuest = { run: async (command, args, timeout) => {
      if (args[5]?.includes('setsid')) throw new Error('no claude')
      return run(command, args, timeout)
    } }
    const tasks = new AgentTasks(() => guest, () => {}, () => () => {}, 60_000)
    await expect(tasks.start({ prompt: 'x' })).rejects.toThrow('no claude')
    expect(fake.scriptOf(fake.calls.at(-1))).toContain('rm -rf')
    expect(tasks.list()).toEqual([])
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

  it('restores tasks from the guest after a host restart, still able to reply', async () => {
    const running = '11111111-1111-4111-8111-111111111111'
    const done = '22222222-2222-4222-8222-222222222222'
    const orphan = '33333333-3333-4333-8333-333333333333'
    const listing = [
      [running, 'codex', '1790000300', '', '1', '512', b64('keep going'), b64('{}'), 'auto', '1', '', ''],
      [done, 'claude', '1790000200', '0', '0', '900', b64('run tests'), b64(JSON.stringify(result('All green.'))),
        'ask', '3', b64(JSON.stringify(init('c237ef1f-3019-47c0-b325-b54d7cb4781d'))), b64('shot.png\n')],
      [orphan, 'claude', '1790000100', '', '0', '10', b64('lost'), '', 'auto', '1', b64('6d1e7c1a-0000-4000-8000-000000000000'), ''],
    ].map(fields => fields.join('\t')).join('\n')
    const fake = fakeGuest()
    fake.setListing(listing)
    const events: AgentEvent[] = []
    const release = vi.fn()
    const acquire = vi.fn(() => release)
    const tasks = new AgentTasks(() => fake.guest, event => events.push(event), acquire, 60_000)
    await tasks.restore()
    await tasks.restore()
    expect(tasks.list().map(task => [task.id, task.status, task.agent])).toEqual([
      [running, 'running', 'codex'], [done, 'succeeded', 'claude'], [orphan, 'failed', 'claude'],
    ])
    expect(tasks.list()[0]?.prompt).toBe('keep going')
    expect(tasks.list()[1]).toMatchObject({ summary: 'All green.', turns: 3, approvals: 'ask', attachments: [`/home/caboose/Agents/${done}/attachments/shot.png`] })
    expect(acquire).toHaveBeenCalledTimes(1)
    expect(events).toEqual([])
    await tasks.reply(done, { prompt: 'and lint' })
    const launch = fake.calls.at(-1)!
    expect(launch.slice(8)).toEqual([`/home/caboose/Agents/${done}`, 'and lint', 'c237ef1f-3019-47c0-b325-b54d7cb4781d', '4'])
    expect(fake.scriptOf(launch)).toContain('--permission-prompt-tool')
    // The new turn is read from where the transcript ended.
    expect(tasks.list().find(task => task.id === done)?.status).toBe('running')
    await tasks.poll()
    const poll = fake.calls.find(call => fake.scriptOf(call)?.startsWith('max=$1'))!
    expect(poll.slice(poll.indexOf(`/home/caboose/Agents/${done}`), poll.indexOf(`/home/caboose/Agents/${done}`) + 2)).toEqual([`/home/caboose/Agents/${done}`, '900'])
    await tasks.reply(orphan, { prompt: 'retry' })
    expect(fake.calls.at(-1)).toContain('6d1e7c1a-0000-4000-8000-000000000000')
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

describe('parsePoll', () => {
  it('ignores lines that are not task or request records', () => {
    const id = '11111111-1111-4111-8111-111111111111'
    const reports = parsePoll(`garbage\nT\t${id}\t0\t${b64('err')}\t${b64('{"a":1}\n')}\nA\t${id}\t${REQUEST}\t${b64('{}')}\nA\t${id}\t../x\t\nT\tnot-an-id\t\t\t\n`)
    expect([...reports.keys()]).toEqual([id])
    expect(reports.get(id)).toMatchObject({ exitCode: '0', stderr: 'err', requests: [{ id: REQUEST, json: '{}' }] })
    expect(reports.get(id)?.data.toString()).toBe('{"a":1}\n')
  })
})
