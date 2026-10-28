// The real runner against a stand-in ACP agent: no model, no network (the binary download
// is served from localhost). Each test gets its own home, task directory and agent state.
import { execFile, spawn } from 'node:child_process'
import { createHash } from 'node:crypto'
import { chmod, mkdir, mkdtemp, readdir, readFile, rename, rm, stat, utimes, writeFile } from 'node:fs/promises'
import { createServer } from 'node:http'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { promisify } from 'node:util'
import { afterEach, describe, expect, it } from 'vitest'
import { chooseOption, describeToolCall, Draft, isStaleLock, latestPage, launchCommand, loopbackURL, Normaliser, publicAuthMethods, readSpec, recapFrom } from '../caboose-agentd.mjs'

const RUNNER = new URL('../caboose-agentd.mjs', import.meta.url).pathname
const STAND_IN = new URL('./stand-in-agent.mjs', import.meta.url).pathname
const DESKTOP_MCP = new URL('../../desktop-mcp/caboose-desktop-mcp.mjs', import.meta.url).pathname
const cleanup = []
afterEach(async () => {
  for (const step of cleanup.splice(0).reverse()) await step()
})

const AGENT = { id: 'stand-in', name: 'Stand-in', version: '1.0.0', distribution: 'npx', package: '@example/stand-in@1.0.0', args: [], env: {} }

async function sandbox({ caps = '', auth = false } = {}) {
  const root = await mkdtemp(join(tmpdir(), 'caboose-agentd-'))
  cleanup.push(() => rm(root, { recursive: true, force: true }))
  const home = join(root, 'home')
  const bin = join(root, 'bin')
  const state = join(root, 'state')
  await mkdir(home, { recursive: true })
  await mkdir(bin, { recursive: true })
  // npx -y <package> <args…> runs the stand-in; npm records what a prefetch asked for.
  await writeFile(join(bin, 'npx'), `#!/bin/sh\nshift 2\nexec "${process.execPath}" "${STAND_IN}" "$@"\n`)
  await writeFile(join(bin, 'npm'), `#!/bin/sh\nprintf '%s\\n' "$*" >> "${root}/npm.log"\n`)
  // A terminal emulator that runs its command in the foreground, as -e … would.
  await writeFile(join(bin, 'x-terminal-emulator'), `#!/bin/sh\nshift\nprintf '%s %s %s\\n' "$DISPLAY" "\${WAYLAND_DISPLAY:-none}" "$STAND_IN_LOGIN" > "${root}/terminal.log"\necho | "$@"\n`)
  for (const name of ['npx', 'npm', 'x-terminal-emulator']) await chmod(join(bin, name), 0o755)
  const env = {
    ...process.env, HOME: home, PATH: `${bin}:${process.env.PATH}`, DISPLAY: ':101',
    STAND_IN_STATE: state, STAND_IN_CAPS: caps, STAND_IN_AUTH: auth ? '1' : '',
    CABOOSE_DESKTOP_MCP: DESKTOP_MCP, CABOOSE_AGENTD_POLL_MS: '30', CABOOSE_AGENTD_CANCEL_GRACE_MS: '600',
  }
  return { root, home, state, env }
}

async function task(options = {}) {
  const box = await sandbox(options)
  const dir = join(box.home, 'Agents', 'task-1')
  await mkdir(join(dir, 'inbox'), { recursive: true })
  await writeFile(join(dir, 'task.json'), JSON.stringify({ agent: options.agent ?? AGENT, cwd: dir, approvals: options.approvals ?? 'auto', idleMs: options.idleMs ?? 20_000, craftServers: options.craftServers }))
  let runner
  const t = {
    ...box, dir,
    async prompt(turn, text, extra = {}) {
      await writeFile(join(dir, 'inbox', `.${turn}.tmp`), JSON.stringify({ type: 'prompt', turn, text, ...extra }))
      await import('node:fs/promises').then(fs => fs.rename(join(dir, 'inbox', `.${turn}.tmp`), join(dir, 'inbox', `${String(turn).padStart(6, '0')}.prompt.json`)))
    },
    async cancel() { await writeFile(join(dir, 'inbox', `cancel-${Date.now()}.json`), '{"type":"cancel"}') },
    start() {
      const child = spawn(process.execPath, [RUNNER, 'run', dir], { env: box.env, stdio: ['ignore', 'ignore', 'pipe'] })
      let stderr = ''
      child.stderr.on('data', chunk => { stderr += chunk })
      const exited = new Promise(resolve => child.on('exit', code => resolve(code)))
      runner = { child, exited, stderr: () => stderr }
      cleanup.push(async () => { if (child.exitCode === null) { child.kill('SIGKILL'); await exited } })
      return runner
    },
    async events() {
      const text = await readFile(join(dir, 'transcript.jsonl'), 'utf8').catch(() => '')
      return text.split('\n').filter(Boolean).map(line => JSON.parse(line))
    },
    async until(what, check) {
      for (let i = 0; i < 300; i++) {
        const events = await t.events()
        const found = check(events)
        if (found) return found
        await new Promise(resolve => setTimeout(resolve, 50))
      }
      throw new Error(`Timed out waiting for ${what}: ${JSON.stringify(await t.events())}\n${runner?.stderr()}`)
    },
    turnEnd: turn => t.until(`turn ${turn} to end`, events => events.find(event => ['turn_end', 'turn_failed', 'auth_required'].includes(event.type) && event.turn === turn)),
    texts: async turn => {
      const events = await t.events()
      const start = events.findIndex(event => event.type === 'user' && event.turn === turn)
      const end = events.findIndex((event, index) => index > start && event.turn === turn && event.type !== 'user')
      return events.slice(start, end).filter(event => event.type === 'text').map(event => event.text)
    },
  }
  return t
}

async function decide(dir, id, decision) {
  const path = join(dir, 'approvals', `${id}.decision`)
  const temporary = path + '.tmp'
  await writeFile(temporary, JSON.stringify(decision))
  await rename(temporary, path)
}

async function pendingApproval(dir) {
  for (let i = 0; i < 200; i++) {
    const names = await readdir(join(dir, 'approvals')).catch(() => [])
    const request = names.find(name => name.endsWith('.json') && !name.startsWith('.') && !names.includes(name.replace(/\.json$/, '.decision')))
    if (request) return { id: request.replace(/\.json$/, ''), body: JSON.parse(await readFile(join(dir, 'approvals', request), 'utf8')) }
    await new Promise(resolve => setTimeout(resolve, 30))
  }
  throw new Error('no approval request')
}

describe('a turn', () => {
  it('offers profile tools only when the host enables them on a profile task', async () => {
    const t = await task()
    const config = JSON.parse(await readFile(join(t.dir, 'task.json'), 'utf8'))
    await writeFile(join(t.dir, 'task.json'), JSON.stringify({ ...config, profileId: '11111111-1111-4111-8111-111111111111', agentTools: true }))
    await writeFile(join(t.dir, 'profile-instructions.txt'), 'Be helpful.')
    await t.prompt(1, 'hello')
    t.start()
    await t.turnEnd(1)
    expect((await t.texts(1)).some(text => text.includes('mcp: caboose-desktop,caboose-agent-tools'))).toBe(true)
    for (let i = 0; i < 50 && await stat(join(t.dir, 'tool-turn')).then(() => true, () => false); i++) await new Promise(resolve => setTimeout(resolve, 20))
    await expect(stat(join(t.dir, 'tool-turn'))).rejects.toThrow()
  })

  it('offers installed catalog servers to an ACP session', async () => {
    const t = await task({ craftServers: [
      { name: 'caboose-photocraft', command: 'photocraft-cli', args: ['mcp'], env: [] },
      { name: 'bad', command: 'sh', args: ['-c', 'bad command'], env: [] },
    ] })
    await t.prompt(1, 'hello')
    t.start()
    await t.turnEnd(1)
    expect(await t.texts(1)).toContain('turns in session: 1; mcp: caboose-desktop,caboose-photocraft; blocks: text; recap: no; display: :101')
  })

  it('streams an agent-neutral transcript', async () => {
    const t = await task()
    await t.prompt(1, 'hello tool plan')
    t.start()
    const end = await t.turnEnd(1)
    expect(end).toMatchObject({ type: 'turn_end', stopReason: 'end_turn', summary: 'done: hello tool plan' })
    const events = await t.events()
    expect(events.map(event => event.type)).toEqual(['user', 'session', 'thought', 'text', 'text', 'tool', 'tool_update', 'tool_update', 'plan', 'text', 'usage', 'turn_end'])
    // Chunks of one message are one line; the agent got the desktop tools on the agent seat.
    expect(events[3].text).toBe('heard: hello tool plan')
    expect(events[4].text).toBe('turns in session: 1; mcp: caboose-desktop; blocks: text; recap: no; display: :101')
    expect(events[1]).toMatchObject({ continuity: 'new', agent: { name: 'stand-in' }, modes: { currentModeId: 'default' } })
    expect(events[5]).toMatchObject({ id: 'call-1', title: 'Run echo hi', kind: 'execute', status: 'pending', detail: 'echo hi' })
    expect(events.at(-2)).toMatchObject({ type: 'usage', used: 100, size: 1000 })
  })

  it('saves the message being written as a draft, gone once the message is whole', async () => {
    const t = await task()
    await t.prompt(1, 'please stream')
    t.start()
    const draftPath = join(t.dir, 'draft.json')
    let draft
    for (let i = 0; i < 100 && !draft; i++) {
      const read = JSON.parse(await readFile(draftPath, 'utf8').catch(() => 'null'))
      if (read?.text?.startsWith('one two')) draft = read
      else await new Promise(resolve => setTimeout(resolve, 20))
    }
    expect(draft).toMatchObject({ kind: 'text', turn: 1 })
    expect(Number.isSafeInteger(draft.after)).toBe(true)
    expect(draft.after).toBeGreaterThan(0)
    await t.turnEnd(1)
    expect((await t.texts(1)).map(text => text.trim())).toContain('one two three four five six')
    await expect(stat(draftPath)).rejects.toThrow()
  })

  it('answers permission requests itself with approvals "auto"', async () => {
    const t = await task()
    await t.prompt(1, 'ask')
    t.start()
    await t.turnEnd(1)
    expect(await t.texts(1)).toContain('permission: yes')
    expect((await t.events()).find(event => event.type === 'permission')).toMatchObject({ auto: true, kind: 'allow_once', summary: 'Delete build: rm -rf build' })
    expect(await readdir(join(t.dir, 'approvals'))).toEqual([])
  })

  it('asks the owner with approvals "ask", in the files the host reads', async () => {
    const t = await task({ approvals: 'ask' })
    await t.prompt(1, 'ask')
    t.start()
    const first = await pendingApproval(t.dir)
    expect(first.id).toMatch(/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/)
    expect(first.body).toMatchObject({
      tool: 'Delete build', kind: 'delete', summary: 'Delete build: rm -rf build', input: { command: 'rm -rf build' },
      options: [{ id: 'yes', name: 'Allow', kind: 'allow_once' }, { id: 'always', name: 'Always allow', kind: 'allow_always' }, { id: 'no', name: 'Reject', kind: 'reject_once' }],
    })
    await decide(t.dir, first.id, { allow: false, message: 'Not now.' })
    await t.turnEnd(1)
    expect(await t.texts(1)).toContain('permission: no')
    expect((await t.events()).find(event => event.type === 'permission_resolved')).toMatchObject({ allow: false, optionId: 'no', message: 'Not now.' })
    // A named option wins over the plain allow.
    await t.prompt(2, 'ask')
    const second = await pendingApproval(t.dir)
    await decide(t.dir, second.id, { allow: true, optionId: 'always' })
    await t.turnEnd(2)
    expect(await t.texts(2)).toContain('permission: always')
  })

  it('cancels a turn, answering a waiting permission request "cancelled"', async () => {
    const t = await task({ approvals: 'ask' })
    await t.prompt(1, 'slow')
    t.start()
    await t.until('the turn to start', events => events.some(event => event.type === 'session'))
    await t.cancel()
    expect(await t.turnEnd(1)).toMatchObject({ stopReason: 'cancelled', summary: 'stopping' })
    await t.prompt(2, 'ask')
    const request = await pendingApproval(t.dir)
    await t.cancel()
    expect(await t.turnEnd(2)).toMatchObject({ stopReason: 'cancelled' })
    expect(JSON.parse(await readFile(join(t.dir, 'approvals', `${request.id}.decision`), 'utf8'))).toEqual({ allow: false, cancelled: true })
  })

  it('stops an agent that ignores the cancel, and a reply starts it again', async () => {
    const t = await task()
    await t.prompt(1, 'stubborn')
    t.start()
    await t.until('the turn to start', events => events.some(event => event.type === 'session'))
    await t.cancel()
    expect(await t.turnEnd(1)).toMatchObject({ stopReason: 'cancelled' })
    await t.prompt(2, 'again')
    await t.turnEnd(2)
    const sessions = (await t.events()).filter(event => event.type === 'session')
    expect(sessions.map(event => event.continuity)).toEqual(['new', 'recap'])
  })

  it('keeps the conversation for a reply while it waits', async () => {
    const t = await task()
    await t.prompt(1, 'first')
    t.start()
    await t.turnEnd(1)
    await t.prompt(2, 'second')
    await t.turnEnd(2)
    expect(await t.texts(2)).toContain('turns in session: 2; mcp: caboose-desktop; blocks: text; recap: no; display: :101')
    expect((await t.events()).filter(event => event.type === 'session')).toHaveLength(1)
  })

  it('exits cleanly after its idle time', async () => {
    const t = await task({ idleMs: 300 })
    await t.prompt(1, 'quick')
    const runner = t.start()
    await t.turnEnd(1)
    expect(await runner.exited).toBe(0)
  })

  it('reports a failed turn when the agent dies, and recovers on the next prompt', async () => {
    const t = await task()
    await t.prompt(1, 'crash')
    t.start()
    expect((await t.turnEnd(1)).message).toMatch(/exited with code 3/)
    await t.prompt(2, 'after')
    expect(await t.turnEnd(2)).toMatchObject({ type: 'turn_end', summary: expect.stringContaining('done: after') })
  })

  it('adds the owner\'s private environment file for the agent, and ignores one others can read', async () => {
    const t = await task()
    const dir = join(t.home, '.config', 'caboose', 'agents')
    await mkdir(dir, { recursive: true })
    await writeFile(join(dir, 'stand-in.env'), '# keys for the stand-in\n\nSTAND_IN_GREETING="hello there"\nnot a line\n', { mode: 0o600 })
    await t.prompt(1, 'env')
    const runner = t.start()
    await t.turnEnd(1)
    expect(await t.texts(1)).toContain('env: hello there')
    await chmod(join(dir, 'stand-in.env'), 0o644)
    await t.prompt(2, 'crash')
    await t.turnEnd(2)
    await t.prompt(3, 'env')
    await t.turnEnd(3)
    expect(await t.texts(3)).toContain('env: unset')
    const log = runner.stderr()
    expect(log).toMatch(/ignoring .*stand-in\.env: it must not be readable or writable by group or others/)
    expect(log).toMatch(/ignoring line 4 of/)
    // The runner never logs values; only the agent itself said it, in its own message.
    expect(log).not.toContain('hello there')
    expect((await t.events()).filter(event => JSON.stringify(event).includes('hello there')).map(event => event.type)).toEqual(['text'])
  })

  it('sets and removes variables with set-env, keeps comments, and reports names, never values', async () => {
    const t = await task()
    const dir = join(t.home, '.config', 'caboose', 'agents')
    await mkdir(dir, { recursive: true })
    await writeFile(join(dir, 'stand-in.env'), '# mine\nOLD=1\n', { mode: 0o600 })
    const setEnv = changes => promisify(execFile)(process.execPath, [RUNNER, 'set-env', 'stand-in', JSON.stringify(changes)], { env: t.env })
    const { stdout } = await setEnv({ set: { STAND_IN_GREETING: ' "quoted" with spaces ', OPENROUTER_API_KEY: 'sk-or-1' } })
    expect(JSON.parse(stdout)).toEqual({ env: ['OLD', 'OPENROUTER_API_KEY', 'STAND_IN_GREETING'] })
    expect((await stat(join(dir, 'stand-in.env'))).mode & 0o777).toBe(0o600)
    await t.prompt(1, 'env')
    t.start()
    await t.turnEnd(1)
    expect(await t.texts(1)).toContain('env:  "quoted" with spaces ')
    expect(JSON.parse((await setEnv({ remove: ['OLD'], set: { OPENROUTER_API_KEY: 'sk-or-2' } })).stdout)).toEqual({ env: ['OPENROUTER_API_KEY', 'STAND_IN_GREETING'] })
    expect(await readFile(join(dir, 'stand-in.env'), 'utf8')).toBe('# mine\nSTAND_IN_GREETING=" "quoted" with spaces "\nOPENROUTER_API_KEY="sk-or-2"\n')
    const { stdout: state } = await promisify(execFile)(process.execPath, [RUNNER, 'state'], { env: t.env })
    expect(JSON.parse(state).agents['stand-in'].env).toEqual(['OPENROUTER_API_KEY', 'STAND_IN_GREETING'])
    expect(state).not.toContain('sk-or-2')
    await expect(setEnv({ set: { 'BAD NAME': 'x' } })).rejects.toThrow(/invalid variable name/)
    await expect(setEnv({ set: { KEY: 'two\nlines' } })).rejects.toThrow(/single line/)
  })

  it('reads and writes files for the agent inside the home directory only', async () => {
    const t = await task()
    await t.prompt(1, 'write-home')
    t.start()
    await t.turnEnd(1)
    expect(await t.texts(1)).toContain('read back: two')
    expect(await readFile(join(t.home, 'notes', 'stand-in.txt'), 'utf8')).toBe('one\ntwo\nthree')
    await t.prompt(2, 'write-outside')
    await t.turnEnd(2)
    expect((await t.texts(2)).find(text => text.startsWith('outside write'))).toMatch(/refused.*outside the home directory/)
  })

  it('sends images to agents that take them, and links otherwise', async () => {
    for (const caps of ['image', '']) {
      const t = await task({ caps })
      const photo = join(t.home, 'photo.png')
      await writeFile(photo, Buffer.from([0x89, 0x50, 0x4e, 0x47]))
      const notes = join(t.home, 'notes.txt')
      await writeFile(notes, 'notes')
      await t.prompt(1, 'look', { attachments: [{ path: photo, name: 'photo.png', mimeType: 'image/png' }, { path: notes, name: 'notes.txt' }] })
      t.start()
      await t.turnEnd(1)
      const blocks = caps ? 'text,image:image/png,link:notes.txt' : 'text,link:photo.png,link:notes.txt'
      expect((await t.texts(1)).some(text => text.includes(`blocks: ${blocks};`))).toBe(true)
    }
  })
})

describe('a later runner', () => {
  async function secondRunner(caps) {
    const t = await task({ caps, idleMs: 200 })
    await t.prompt(1, 'first')
    const first = t.start()
    await t.turnEnd(1)
    await first.exited
    await t.prompt(2, 'second')
    t.start()
    await t.turnEnd(2)
    return t
  }

  it('loads the session when the agent can, without repeating the replay', async () => {
    const t = await secondRunner('load')
    const events = await t.events()
    expect(events.filter(event => event.type === 'session').map(event => event.continuity)).toEqual(['new', 'load'])
    expect(await t.texts(2)).toContain('turns in session: 2; mcp: caboose-desktop; blocks: text; recap: no; display: :101')
    expect(events.filter(event => event.type === 'text' && event.text === 'heard: first')).toHaveLength(1)
  })

  it('resumes the session when the agent can', async () => {
    const t = await secondRunner('resume,load')
    expect((await t.events()).filter(event => event.type === 'session').map(event => event.continuity)).toEqual(['new', 'resume'])
    expect(await t.texts(2)).toContain('turns in session: 2; mcp: caboose-desktop; blocks: text; recap: no; display: :101')
  })

  it('starts a new session with a recap, and says so, when the agent cannot reload', async () => {
    const t = await secondRunner('')
    const events = await t.events()
    expect(events.filter(event => event.type === 'session').map(event => event.continuity)).toEqual(['new', 'recap'])
    expect(await t.texts(2)).toContain('turns in session: 1; mcp: caboose-desktop; blocks: text; recap: yes; display: :101')
    expect(events.at(-1).summary).toMatch(/^Stand-in cannot reload conversations, so this turn started a new session with a recap/)
  })
})

describe('sign-in', () => {
  it('reports a signed-out agent with its sign-in methods and stops', async () => {
    const t = await task({ auth: true })
    await t.prompt(1, 'hello')
    const runner = t.start()
    expect(await t.turnEnd(1)).toMatchObject({
      type: 'auth_required',
      authMethods: [
        { id: 'stand-in-login', name: 'Stand-in account', description: 'Sign in through the agent', type: 'agent' },
        { id: 'stand-in-terminal', name: 'Stand-in terminal', type: 'terminal' },
      ],
    })
    expect(await runner.exited).toBe(0)
    const auth = JSON.parse(await readFile(join(t.home, '.local/share/caboose/agents/stand-in/auth.json'), 'utf8'))
    expect(auth.authMethods.map(method => method.id)).toEqual(['stand-in-login', 'stand-in-terminal'])
  })

  const run = (box, mode, value) => promisify(execFile)(process.execPath, [RUNNER, mode, Buffer.from(JSON.stringify(value)).toString('base64')], { env: box.env })
  const signInState = async box => JSON.parse(await readFile(join(box.home, '.local/share/caboose/agents/stand-in/sign-in.json'), 'utf8'))

  it('signs in through the agent, then tasks run', async () => {
    const box = await sandbox({ auth: true })
    await run(box, 'sign-in', { agent: AGENT, methodId: 'stand-in-login', env: { DISPLAY: ':100' } })
    expect(await signInState(box)).toMatchObject({ methodId: 'stand-in-login', status: 'succeeded' })
    expect(await readFile(join(box.state, 'signed-in'), 'utf8')).toBe('agent')
    await expect(run(box, 'sign-in', { agent: AGENT, methodId: 'nope' })).rejects.toThrow()
    expect(await signInState(box)).toMatchObject({ status: 'failed', message: expect.stringContaining('no sign-in method "nope"') })
  })

  it('signs in with a terminal method on the owner display', async () => {
    const box = await sandbox({ auth: true })
    await run(box, 'sign-in', { agent: AGENT, methodId: 'stand-in-terminal', env: { DISPLAY: ':110' } })
    expect(await signInState(box)).toMatchObject({ methodId: 'stand-in-terminal', status: 'succeeded' })
    expect(await readFile(join(box.state, 'signed-in'), 'utf8')).toBe('terminal')
    expect((await readFile(join(box.root, 'terminal.log'), 'utf8')).trim()).toBe(':110 none 1')
  })

  it('opens the terminal with the full launch environment the host sends', async () => {
    const box = await sandbox({ auth: true })
    await run(box, 'sign-in', { agent: AGENT, methodId: 'stand-in-terminal', env: { WAYLAND_DISPLAY: 'wayland-caboose-0', DISPLAY: ':110', 'bad name': 'x' } })
    expect(await signInState(box)).toMatchObject({ methodId: 'stand-in-terminal', status: 'succeeded' })
    expect((await readFile(join(box.root, 'terminal.log'), 'utf8')).trim()).toBe(':110 wayland-caboose-0 1')
  })
})

describe('sign-in on the phone', () => {
  const encode = value => Buffer.from(JSON.stringify(value)).toString('base64')
  const runner = (box, ...args) => promisify(execFile)(process.execPath, [RUNNER, ...args], { env: box.env })
  const signInState = box => readFile(join(box.home, '.local/share/caboose/agents/stand-in/sign-in.json'), 'utf8').then(JSON.parse, () => undefined)
  const until = async (what, check) => {
    for (let i = 0; i < 300; i++) {
      const found = await check()
      if (found) return found
      await new Promise(resolve => setTimeout(resolve, 50))
    }
    throw new Error(`Timed out waiting for ${what}`)
  }

  const A = '0a0a0a0a-0000-4000-8000-00000000000a'
  const B = '0b0b0b0b-0000-4000-8000-00000000000b'
  const statePath = box => join(box.home, '.local/share/caboose/agents/stand-in/sign-in.json')
  const attempts = box => join(box.home, '.local/share/caboose/agents/stand-in/attempts')
  const alive = pid => { try { process.kill(pid, 0); return true } catch { return false } }
  /** The state once attempt `attempt` has handed over its page. */
  const page = (box, attempt) => until(`the page of ${attempt}`, async () => { const state = await signInState(box); return state?.attempt === attempt && state.url && state })
  /** Waits until process `pid` holds the agent's sign-in lock. */
  const lockedBy = (box, pid) => until(`${pid} to hold the lock`, async () =>
    JSON.parse(await readFile(join(statePath(box), '..', 'sign-in.lock'), 'utf8').catch(() => '{}')).pid === pid)

  /** A runner signing in, started as the host starts it: in its own process group. */
  function signingIn(box, value) {
    const child = spawn(process.execPath, [RUNNER, 'sign-in', encode(value)], { env: box.env, detached: true, stdio: 'ignore' })
    const exited = new Promise(resolve => child.on('exit', (code, signal) => resolve(signal ?? code)))
    cleanup.push(async () => { if (child.exitCode === null && child.signalCode === null) { try { process.kill(-child.pid, 'SIGKILL') } catch {} await exited } })
    return { child, exited }
  }

  /** The computer's terminal service as the runner uses it: start a program, list and hang up sessions. */
  async function terminalService(box) {
    const token = join(box.root, 'terminal-token')
    await writeFile(token, 'terminal-secret')
    const sessions = new Map()
    const server = createServer((request, response) => {
      const url = new URL(request.url, 'http://127.0.0.1')
      if (request.headers.authorization !== 'Bearer terminal-secret') { response.writeHead(401).end('{"error":"unauthorized"}'); return }
      if (url.pathname === '/start') {
        const argv = JSON.parse(Buffer.from(url.searchParams.get('argv'), 'base64url').toString())
        const id = createHash('sha256').update(String(Math.random())).digest('hex').slice(0, 32)
        // A session has the service's own environment and the owner display's, never the runner's.
        const child = spawn(argv[0], argv.slice(1), { env: { ...process.env, HOME: box.home, DISPLAY: ':101', STAND_IN_STATE: box.state }, stdio: 'ignore' })
        sessions.set(id, child)
        child.on('exit', () => sessions.delete(id))
        response.end(JSON.stringify({ session: id }))
      } else if (url.pathname === '/sessions') {
        response.end(JSON.stringify({ sessions: [...sessions.keys()].map(id => ({ id })) }))
      } else if (url.pathname === '/hangup') {
        sessions.get(url.searchParams.get('session'))?.kill('SIGHUP')
        response.end('{"hungUp":true}')
      } else {
        response.writeHead(404).end('{}')
      }
    })
    await new Promise(resolve => server.listen(0, '127.0.0.1', resolve))
    cleanup.push(() => new Promise(resolve => { for (const child of sessions.values()) child.kill('SIGKILL'); server.close(resolve) }))
    Object.assign(box.env, { CABOOSE_TERMINAL_PORT: String(server.address().port), CABOOSE_TERMINAL_TOKEN_FILE: token })
  }

  it('takes the latest web page, and delivers only to the computer\'s loopback', () => {
    expect(latestPage('https://a.example/1\nnot a page\nfile:///etc/passwd\nhttps://b.example/2\n\n')).toBe('https://b.example/2')
    expect(latestPage('')).toBeUndefined()
    expect(loopbackURL('http://localhost:1455/auth/callback?code=x').port).toBe('1455')
    expect(loopbackURL('http://127.0.0.1:8080/').hostname).toBe('127.0.0.1')
    expect(loopbackURL('http://[::1]:8080/').hostname).toBe('[::1]')
    for (const value of ['https://localhost:1455/', 'http://localhost/', 'http://example.com:1455/', 'http://user:pw@localhost:1455/', 'nope', 'http://localhost.example.com:80/']) {
      expect(() => loopbackURL(value), value).toThrow()
    }
  })

  it('hands the sign-in page to the phone and delivers where it sends the browser back', async () => {
    const box = await sandbox({ auth: true })
    box.env.STAND_IN_CALLBACK = '1'
    const { exited } = signingIn(box, { agent: AGENT, methodId: 'stand-in-login', env: { DISPLAY: ':100' }, on: 'phone', attempt: A })
    const waiting = await page(box, A)
    expect(waiting).toMatchObject({ methodId: 'stand-in-login', status: 'running', on: 'phone', attempt: A, url: expect.stringMatching(/^https:\/\/example\.com\/authorize\?/) })
    // Nothing points the agent at the desktop, so no browser opens there.
    expect(await readFile(join(box.state, 'sign-in-env'), 'utf8')).toBe('none none')
    const back = `${new URL(waiting.url).searchParams.get('redirect_uri')}?code=abc`
    await expect(runner(box, 'sign-in-callback', 'stand-in', A, 'https://example.com/callback?code=1')).rejects.toThrow(/localhost/)
    await expect(runner(box, 'sign-in-callback', 'stand-in', A, `http://localhost/callback?code=1`)).rejects.toThrow(/localhost:<port>/)
    await expect(runner(box, 'sign-in-callback', 'stand-in', back)).rejects.toThrow(/attempt must be a UUID/)
    await expect(runner(box, 'sign-in-callback', 'stand-in', B, back)).rejects.toThrow(/No sign-in is waiting/)
    const { stdout } = await runner(box, 'sign-in-callback', 'stand-in', A, back)
    expect(JSON.parse(stdout).status).toBeLessThan(400)
    expect(await exited).toBe(0)
    expect(await signInState(box)).toMatchObject({ status: 'succeeded', on: 'phone', attempt: A })
    expect(await readFile(join(box.state, 'signed-in'), 'utf8')).toBe('agent')
    await expect(runner(box, 'sign-in-callback', 'stand-in', A, back)).rejects.toThrow(/No sign-in is waiting/)
  })

  it('runs a terminal method in a terminal session for the phone, without the desktop', async () => {
    const box = await sandbox({ auth: true })
    await terminalService(box)
    expect(await signingIn(box, { agent: AGENT, methodId: 'stand-in-terminal', env: { DISPLAY: ':110' }, on: 'phone' }).exited).toBe(0)
    expect(await signInState(box)).toMatchObject({ methodId: 'stand-in-terminal', status: 'succeeded', on: 'phone', attempt: expect.stringMatching(/^[0-9a-f-]{36}$/), terminal: expect.stringMatching(/^[0-9a-f]{32}$/) })
    expect(await readFile(join(box.state, 'signed-in'), 'utf8')).toBe('terminal')
    expect(await readFile(join(box.state, 'sign-in-env'), 'utf8')).toBe('none 1')
    // The environment file the session read, and the rest of the attempt's files, are gone.
    expect(await readdir(attempts(box))).toEqual([])
  })

  it('reports a computer whose terminal service cannot be reached', async () => {
    const box = await sandbox({ auth: true })
    await writeFile(join(box.root, 'terminal-token'), 'terminal-secret')
    Object.assign(box.env, { CABOOSE_TERMINAL_PORT: '9', CABOOSE_TERMINAL_TOKEN_FILE: join(box.root, 'terminal-token') })
    expect(await signingIn(box, { agent: AGENT, methodId: 'stand-in-terminal', on: 'phone' }).exited).toBe(1)
    expect(await signInState(box)).toMatchObject({ status: 'failed', message: expect.stringContaining('terminal service did not answer') })
  })

  it('replaces a running attempt, and cancels only the attempt it is told', async () => {
    const box = await sandbox({ auth: true })
    box.env.STAND_IN_CALLBACK = '1'
    const first = signingIn(box, { agent: AGENT, methodId: 'stand-in-login', on: 'phone', attempt: A })
    await page(box, A)
    const second = signingIn(box, { agent: AGENT, methodId: 'stand-in-login', on: 'phone', attempt: B })
    expect(await first.exited).toBe('SIGTERM')
    expect(await page(box, B)).toMatchObject({ status: 'running', pid: second.child.pid })
    await expect(runner(box, 'sign-in-cancel', 'stand-in')).rejects.toThrow(/attempt must be a UUID/)
    // The replaced attempt's sheet cancelling late leaves the newer attempt running.
    expect(JSON.parse((await runner(box, 'sign-in-cancel', 'stand-in', A)).stdout)).toEqual({ cancelled: false })
    expect(alive(second.child.pid)).toBe(true)
    expect(await signInState(box)).toMatchObject({ status: 'running', attempt: B })
    expect(JSON.parse((await runner(box, 'sign-in-cancel', 'stand-in', B)).stdout)).toEqual({ cancelled: true })
    expect(await second.exited).toBe('SIGTERM')
    const cancelled = await signInState(box)
    expect(cancelled).toMatchObject({ status: 'failed', attempt: B, message: 'Sign-in cancelled.' })
    expect(cancelled).not.toHaveProperty('pid')
    expect(JSON.parse((await runner(box, 'sign-in-cancel', 'stand-in', B)).stdout)).toEqual({ cancelled: false })
    // Neither stopped attempt leaves its files behind.
    expect(await readdir(attempts(box))).toEqual([])
  })

  it('serializes overlapping starts, so the later one always replaces the earlier', async () => {
    const box = await sandbox({ auth: true })
    // Each start pauses between reading the state and recording itself: the first is still there
    // when the second arrives, which without the lock would record over it.
    Object.assign(box.env, { STAND_IN_CALLBACK: '1', CABOOSE_AGENTD_SIGN_IN_PAUSE_MS: '400' })
    const first = signingIn(box, { agent: AGENT, methodId: 'stand-in-login', on: 'phone', attempt: A })
    await lockedBy(box, first.child.pid)
    expect(await signInState(box)).toBeUndefined()
    const second = signingIn(box, { agent: AGENT, methodId: 'stand-in-login', on: 'phone', attempt: B })
    expect(await first.exited).toBe('SIGTERM')
    expect(await page(box, B)).toMatchObject({ status: 'running', pid: second.child.pid })
    expect(alive(second.child.pid)).toBe(true)
  })

  it('never lets a cancel that overlaps a newer start stop it', async () => {
    const box = await sandbox({ auth: true })
    box.env.STAND_IN_CALLBACK = '1'
    const first = signingIn(box, { agent: AGENT, methodId: 'stand-in-login', on: 'phone', attempt: A })
    await page(box, A)
    const second = signingIn({ ...box, env: { ...box.env, CABOOSE_AGENTD_SIGN_IN_PAUSE_MS: '600' } },
      { agent: AGENT, methodId: 'stand-in-login', on: 'phone', attempt: B })
    // The newer start holds the lock and has not recorded itself yet; A's cancel waits for it.
    await lockedBy(box, second.child.pid)
    const cancel = runner(box, 'sign-in-cancel', 'stand-in', A)
    expect(JSON.parse((await cancel).stdout)).toEqual({ cancelled: false })
    expect(await first.exited).toBe('SIGTERM')
    expect(alive(second.child.pid)).toBe(true)
    expect(await signInState(box)).toMatchObject({ status: 'running', attempt: B, pid: second.child.pid })
  })

  it('stops a replaced runner that survived, without recording over or cleaning up after its replacement', async () => {
    const box = await sandbox({ auth: true })
    box.env.STAND_IN_CALLBACK = '1'
    const first = signingIn(box, { agent: AGENT, methodId: 'stand-in-login', on: 'phone', attempt: A })
    await page(box, A)
    // A newer attempt took over without stopping this runner, and has its own files.
    const newer = { methodId: 'stand-in-login', status: 'running', startedAt: 'later', on: 'phone', attempt: B, pid: 1 }
    await writeFile(statePath(box), JSON.stringify(newer))
    await mkdir(join(attempts(box), B, 'bin'), { recursive: true })
    await writeFile(join(attempts(box), B, 'pages'), 'https://example.com/the-newer-page\n')
    await writeFile(join(attempts(box), B, 'bin', 'xdg-open'), '#!/bin/sh\n')
    // The old runner's next record of progress finds it was replaced.
    await writeFile(join(attempts(box), A, 'pages'), 'https://example.com/a-later-page\n', { flag: 'a' })
    expect(await first.exited).toBe(1)
    expect(await signInState(box)).toEqual(newer)
    expect(await readdir(attempts(box))).toEqual([B])
    expect(await readFile(join(attempts(box), B, 'pages'), 'utf8')).toBe('https://example.com/the-newer-page\n')
    expect(await readdir(join(attempts(box), B, 'bin'))).toEqual(['xdg-open'])
  })

  it('never brings a cancelled or finished attempt back with a late report', async () => {
    const box = await sandbox({ auth: true })
    box.env.STAND_IN_CALLBACK = '1'
    const first = signingIn(box, { agent: AGENT, methodId: 'stand-in-login', on: 'phone', attempt: A })
    const waiting = await page(box, A)
    // Cancelled as recorded, while its runner has not stopped yet.
    const { pid: _pid, ...rest } = waiting
    const cancelled = { ...rest, status: 'failed', message: 'Sign-in cancelled.', finishedAt: 'now' }
    await writeFile(statePath(box), JSON.stringify(cancelled))
    await writeFile(join(attempts(box), A, 'pages'), 'https://example.com/a-later-page\n', { flag: 'a' })
    expect(await first.exited).toBe(1)
    expect(await signInState(box)).toEqual(cancelled)
    await expect(readdir(join(attempts(box), A))).rejects.toThrow()
  })

  it('refuses a stale sheet\'s callback once a newer attempt has replaced it', async () => {
    const box = await sandbox({ auth: true })
    box.env.STAND_IN_CALLBACK = '1'
    const first = signingIn(box, { agent: AGENT, methodId: 'stand-in-login', on: 'phone', attempt: A })
    const oldPage = await page(box, A)
    const second = signingIn(box, { agent: AGENT, methodId: 'stand-in-login', on: 'phone', attempt: B })
    expect(await first.exited).toBe('SIGTERM')
    const newPage = await page(box, B)
    const back = state => `${new URL(state.url).searchParams.get('redirect_uri')}?code=abc`
    await expect(runner(box, 'sign-in-callback', 'stand-in', A, back(oldPage))).rejects.toThrow(/No sign-in is waiting/)
    await expect(runner(box, 'sign-in-callback', 'stand-in', A, back(newPage))).rejects.toThrow(/No sign-in is waiting/)
    expect(await signInState(box)).toMatchObject({ status: 'running', attempt: B })
    await runner(box, 'sign-in-callback', 'stand-in', B, back(newPage))
    expect(await second.exited).toBe(0)
    expect(await signInState(box)).toMatchObject({ status: 'succeeded', attempt: B })
  })

  it('takes over a lock its holder left behind, and waits for a live one', async () => {
    const box = await sandbox()
    const lock = join(statePath(box), '..', 'sign-in.lock')
    await mkdir(join(lock, '..'), { recursive: true })
    const dead = spawn(process.execPath, ['-e', ''])
    await new Promise(resolve => dead.on('exit', resolve))
    // A holder that died, one that never wrote its lock, and one alive but long past any work.
    for (const [content, age] of [[JSON.stringify({ pid: dead.pid, token: 't', at: Date.now() }), 0], ['', 60_000],
      [JSON.stringify({ pid: process.pid, token: 't', at: Date.now() - 180_000 }), 0]]) {
      await writeFile(lock, content)
      if (age) await utimes(lock, new Date(Date.now() - age), new Date(Date.now() - age))
      expect(JSON.parse((await runner(box, 'sign-in-cancel', 'stand-in', A)).stdout)).toEqual({ cancelled: false })
      await expect(stat(lock)).rejects.toThrow()
    }
    await writeFile(lock, JSON.stringify({ pid: process.pid, token: 't', at: Date.now() }))
    let settled = false
    const waiting = runner(box, 'sign-in-cancel', 'stand-in', A).finally(() => { settled = true })
    await new Promise(resolve => setTimeout(resolve, 500))
    expect(settled).toBe(false)
    await rm(lock)
    expect(JSON.parse((await waiting).stdout)).toEqual({ cancelled: false })
  })

  it('never signals a process that is not the recorded attempt\'s runner', async () => {
    const box = await sandbox({ auth: true })
    box.env.STAND_IN_CALLBACK = '1'
    const other = signingIn(box, { agent: AGENT, methodId: 'stand-in-login', on: 'phone', attempt: B })
    await page(box, B)
    const sleeper = spawn('sleep', ['30'], { detached: true, stdio: 'ignore' })
    cleanup.push(async () => { try { process.kill(sleeper.pid, 'SIGKILL') } catch {} })
    // A record whose pid is some other program, then one whose pid runs a different attempt.
    for (const pid of [sleeper.pid, other.child.pid]) {
      await writeFile(statePath(box), JSON.stringify({ methodId: 'stand-in-login', status: 'running', on: 'phone', attempt: A, pid }))
      expect(JSON.parse((await runner(box, 'sign-in-cancel', 'stand-in', A)).stdout)).toEqual({ cancelled: true })
      expect(alive(pid)).toBe(true)
    }
  })

  it('judges a lock stale only when its holder is gone, unwritten or far too old', () => {
    const now = 1_000_000_000
    expect(isStaleLock('', now - 1000, now)).toBe(false)
    expect(isStaleLock('{', now - 60_000, now)).toBe(true)
    expect(isStaleLock(JSON.stringify({ pid: process.pid, at: now - 1000 }), now, now)).toBe(false)
    expect(isStaleLock(JSON.stringify({ pid: process.pid, at: now - 121_000 }), now, now)).toBe(true)
    expect(isStaleLock(JSON.stringify({ pid: process.pid }), now, now)).toBe(true)
    expect(isStaleLock(JSON.stringify({ pid: 0, at: now }), now, now)).toBe(true)
  })
})

describe('install', () => {
  it('prefetches an npx agent, learns its sign-in methods and records it', async () => {
    const box = await sandbox()
    const { stdout } = await promisify(execFile)(process.execPath, [RUNNER, 'install', Buffer.from(JSON.stringify(AGENT)).toString('base64')], { env: box.env })
    expect(JSON.parse(stdout)).toEqual({
      installed: { version: '1.0.0' },
      signIn: [
        { id: 'stand-in-login', name: 'Stand-in account', description: 'Sign in through the agent', type: 'agent' },
        { id: 'stand-in-terminal', name: 'Stand-in terminal', type: 'terminal' },
      ],
    })
    expect(await readFile(join(box.root, 'npm.log'), 'utf8')).toBe('exec --yes --package=@example/stand-in@1.0.0 -- node -e \n')
    const { stdout: state } = await promisify(execFile)(process.execPath, [RUNNER, 'state'], { env: box.env })
    expect(JSON.parse(state).agents['stand-in']).toMatchObject({ installed: { version: '1.0.0', spec: AGENT }, authMethods: [{ id: 'stand-in-login' }, { id: 'stand-in-terminal' }] })
  })

  it('downloads a binary agent, checks its sha256, and runs it from its version directory', async () => {
    const box = await sandbox()
    const build = join(box.root, 'build')
    await mkdir(join(build, 'bin'), { recursive: true })
    await writeFile(join(build, 'bin', 'stand-in'), `#!/bin/sh\nexec "${process.execPath}" "${STAND_IN}" "$@"\n`, { mode: 0o755 })
    await promisify(execFile)('tar', ['-czf', join(box.root, 'stand-in.tar.gz'), '-C', build, 'bin'])
    const archive = await readFile(join(box.root, 'stand-in.tar.gz'))
    const server = createServer((request, response) => {
      if (request.url === '/stand-in-linux-x86_64.tar.gz') response.end(archive)
      else { response.statusCode = 404; response.end() }
    })
    await new Promise(resolve => server.listen(0, '127.0.0.1', resolve))
    cleanup.push(() => new Promise(resolve => server.close(resolve)))
    const url = `http://127.0.0.1:${server.address().port}/stand-in-linux-x86_64.tar.gz`
    const sha256 = createHash('sha256').update(archive).digest('hex')
    const binary = { id: 'stand-in', name: 'Stand-in', version: '2.0.0', distribution: 'binary', archive: url, sha256, cmd: './bin/stand-in', args: [], env: {} }
    const install = value => promisify(execFile)(process.execPath, [RUNNER, 'install', Buffer.from(JSON.stringify(value)).toString('base64')], { env: box.env })
    await expect(install({ ...binary, sha256: '0'.repeat(64) })).rejects.toThrow(/failed verification/)
    await expect(install({ ...binary, sha256: undefined })).rejects.toThrow(/https/)
    const { stdout } = await install(binary)
    expect(JSON.parse(stdout).installed).toEqual({ version: '2.0.0' })
    const dir = join(box.home, '.local/share/caboose/agents/stand-in/2.0.0')
    expect(await readdir(join(dir, 'bin'))).toEqual(['stand-in'])
    // A task with the binary agent runs the unpacked command.
    const t = await task({ agent: binary })
    t.env.HOME = box.home
    t.env.PATH = process.env.PATH
    await t.prompt(1, 'binary')
    t.start()
    expect(await t.turnEnd(1)).toMatchObject({ type: 'turn_end', summary: 'done: binary' })
  })
})

describe('pure parts', () => {
  it('validates specs and builds launch commands', () => {
    expect(launchCommand(readSpec({ ...AGENT, args: ['--acp'] }))).toEqual({ command: 'npx', args: ['-y', '@example/stand-in@1.0.0', '--acp'] })
    expect(launchCommand(readSpec({ ...AGENT, distribution: 'uvx', package: 'stand-in==1.0' }), ['--login'])).toEqual({ command: 'uvx', args: ['stand-in==1.0', '--login'] })
    expect(() => readSpec({ ...AGENT, package: '--registry=evil' })).toThrow()
    expect(() => readSpec({ ...AGENT, id: '../x' })).toThrow()
    expect(() => readSpec({ ...AGENT, env: { 'BAD NAME': 'x' } })).toThrow()
    expect(() => launchCommand(readSpec({ ...AGENT, distribution: 'binary', archive: 'https://example.com/a.tgz', cmd: '../../bin/sh' }))).toThrow(/inside/)
  })

  it('picks the option that carries out a decision', () => {
    const options = [{ optionId: 'a', kind: 'allow_always' }, { optionId: 'r', kind: 'reject_once' }]
    expect(chooseOption(options, { allow: true })?.optionId).toBe('a')
    expect(chooseOption(options, { allow: false })?.optionId).toBe('r')
    expect(chooseOption(options, { allow: true, optionId: 'r' })?.optionId).toBe('r')
    expect(chooseOption([{ optionId: 'a', kind: 'allow_once' }], { allow: false })).toBeUndefined()
  })

  it('describes tool calls and sign-in methods for people', () => {
    expect(describeToolCall({ title: 'Run tests', rawInput: { command: 'pnpm test' } })).toBe('Run tests: pnpm test')
    expect(describeToolCall({ title: 'Run `pnpm test`', rawInput: { command: 'pnpm test' } })).toBe('Run `pnpm test`')
    expect(describeToolCall({ kind: 'edit' })).toBe('edit')
    expect(publicAuthMethods([{ id: 'a', name: 'A' }, { id: 't', name: 'T', type: 'terminal', args: ['--x'] }, { id: 'e', name: 'E', type: 'env_var' }, { name: 'no id' }]))
      .toEqual([{ id: 'a', name: 'A', type: 'agent' }, { id: 't', name: 'T', type: 'terminal' }])
  })

  it('recaps earlier turns, newest kept when long', () => {
    const lines = [
      { type: 'user', turn: 1, text: 'one' }, { type: 'turn_end', turn: 1, summary: 'did one' },
      { type: 'user', turn: 2, text: 'two' }, { type: 'turn_failed', turn: 2, message: 'boom' },
      { type: 'user', turn: 3, text: 'three' },
    ].map(event => JSON.stringify(event))
    const recap = recapFrom(lines, 3)
    expect(recap).toContain('Owner: one\nYou: did one\n\nOwner: two\nYou: (failed: boom)')
    expect(recap).not.toContain('three')
    expect(recapFrom([], 1)).toBe('')
  })

  it('coalesces message chunks per message id', async () => {
    const written = []
    const normaliser = new Normaliser({ write: event => { written.push(event) } })
    normaliser.begin()
    normaliser.update({ sessionUpdate: 'agent_message_chunk', messageId: 'a', content: { type: 'text', text: 'Hel' } })
    normaliser.update({ sessionUpdate: 'agent_message_chunk', messageId: 'a', content: { type: 'text', text: 'lo' } })
    normaliser.update({ sessionUpdate: 'agent_message_chunk', messageId: 'b', content: { type: 'text', text: 'Next' } })
    normaliser.update({ sessionUpdate: 'available_commands_update', availableCommands: [] })
    expect(normaliser.end()).toBe('Next')
    expect(written).toEqual([{ type: 'text', text: 'Hello' }, { type: 'text', text: 'Next' }])
    normaliser.update({ sessionUpdate: 'agent_message_chunk', content: { type: 'text', text: 'after the turn' } })
    expect(written).toHaveLength(2)
  })

  it('keeps the draft out of the transcript and removes it before the whole message lands', async () => {
    const steps = []
    const transcript = { write: event => { steps.push(['write', event.type]) }, then: (_step, what) => { steps.push([what]) } }
    const draft = new Draft(transcript, '/nowhere/draft.json')
    const normaliser = new Normaliser(transcript, draft)
    normaliser.begin()
    normaliser.update({ sessionUpdate: 'agent_message_chunk', messageId: 'a', content: { type: 'text', text: 'Hel' } })
    draft.save()
    normaliser.update({ sessionUpdate: 'agent_message_chunk', messageId: 'a', content: { type: 'text', text: 'lo' } })
    normaliser.update({ sessionUpdate: 'tool_call', toolCallId: 'x', title: 'Look' })
    expect(steps).toEqual([['draft removal'], ['draft write'], ['draft removal'], ['write', 'text'], ['write', 'tool']])
    normaliser.end()
  })
})

describe('durable turn receipts', () => {
  const deliveryId = '11111111-1111-4111-8111-111111111111'
  it('durably claims before consuming an inbox and records the terminal result', async () => {
    const t = await task()
    await t.prompt(1, 'slow', { deliveryId })
    const runner = t.start()
    await t.until('prompt execution', events => events.some(event => event.type === 'text'))
    const path = join(t.dir, 'receipts/000001.json')
    expect(JSON.parse(await readFile(path, 'utf8'))).toEqual({ turn: 1, deliveryId, state: 'claimed' })
    await expect(readFile(join(t.dir, 'inbox/000001.prompt.json'))).rejects.toMatchObject({ code: 'ENOENT' })
    await t.cancel(); await t.turnEnd(1)
    for (let i = 0; i < 100; i++) {
      const receipt = JSON.parse(await readFile(path, 'utf8'))
      if (receipt.state === 'completed') {
        expect(receipt).toMatchObject({ turn: 1, deliveryId, result: { type: 'turn_end', turn: 1, stopReason: 'cancelled' } })
        return
      }
      await new Promise(resolve => setTimeout(resolve, 20))
    }
    throw Error(`No completed receipt: ${runner.stderr()}`)
  })

  it.each(['claimed', 'partial'])('never replays a %s receipt left before inbox unlink', async state => {
    const t = await task({ idleMs: 50 })
    await t.prompt(1, 'hello', { deliveryId })
    await mkdir(join(t.dir, 'receipts'))
    await writeFile(join(t.dir, 'receipts/000001.json'), state === 'claimed' ? JSON.stringify({ turn: 1, deliveryId, state }) : '{')
    const runner = t.start()
    expect(await runner.exited).toBe(1)
    expect(runner.stderr()).toContain('uncertain')
    expect(await t.events()).toEqual([])
    expect(await readFile(join(t.dir, 'inbox/000001.prompt.json'), 'utf8')).toContain('hello')
  })

  it('does not execute a completed duplicate, but accepts the next turn', async () => {
    const t = await task({ idleMs: 100 })
    await t.prompt(1, 'duplicate', { deliveryId })
    await mkdir(join(t.dir, 'receipts'))
    await writeFile(join(t.dir, 'receipts/000001.json'), JSON.stringify({ turn: 1, deliveryId, state: 'completed', result: { type: 'turn_end', turn: 1 } }))
    await t.prompt(2, 'hello', { deliveryId: '22222222-2222-4222-8222-222222222222' })
    const runner = t.start()
    await t.turnEnd(2)
    expect(await runner.exited).toBe(0)
    expect((await t.events()).filter(event => event.type === 'user').map(event => event.turn)).toEqual([2])
  })

  it('leaves an interrupted ACP execution claimed and never fabricates a terminal result', async () => {
    const t = await task()
    await t.prompt(1, 'slow', { deliveryId })
    const runner = t.start()
    await t.until('prompt execution', events => events.some(event => event.type === 'text'))
    runner.child.kill('SIGTERM')
    expect(await runner.exited).toBe(143)
    expect(JSON.parse(await readFile(join(t.dir, 'receipts/000001.json'), 'utf8'))).toMatchObject({ state: 'claimed', deliveryId })
    expect((await t.events()).some(event => ['turn_end', 'turn_failed'].includes(event.type))).toBe(false)
    expect((await t.events()).some(event => event.type === 'notice' && event.text.includes('uncertain'))).toBe(true)
  })

  it('does not consume oversized or malformed prompts', async () => {
    const t = await task()
    await t.prompt(1, 'x'.repeat(32001), { deliveryId })
    const runner = t.start()
    expect(await runner.exited).toBe(1)
    expect(runner.stderr()).toContain('Invalid prompt')
    expect(await readFile(join(t.dir, 'inbox/000001.prompt.json'), 'utf8')).toContain('xxx')
    expect(await t.events()).toEqual([])
  })
})


it('supplies persistent profile instructions on every turn without rewriting the owner transcript', async () => {
  const t = await task()
  const config = JSON.parse(await readFile(join(t.dir, 'task.json'), 'utf8'))
  config.profileId = 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee'
  await writeFile(join(t.dir, 'task.json'), JSON.stringify(config))
  await writeFile(join(t.dir, 'profile-instructions.txt'), 'You are the weekly research teammate.')
  t.start()
  await t.prompt(1, 'First report')
  await t.turnEnd(1)
  await t.prompt(2, 'Second report')
  await t.turnEnd(2)
  const sessionName = (await readdir(t.state)).find(name => name.startsWith('session-'))
  const session = JSON.parse(await readFile(join(t.state, sessionName), 'utf8'))
  expect(session.history.map(turn => turn.user)).toEqual(['You are the weekly research teammate.\nFirst report', 'You are the weekly research teammate.\nSecond report'])
  expect((await t.events()).filter(e => e.type === 'user').map(e => e.text)).toEqual(['First report', 'Second report'])
})
