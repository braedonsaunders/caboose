// The real runner against a stand-in ACP agent: no model, no network (the binary download
// is served from localhost). Each test gets its own home, task directory and agent state.
import { execFile, spawn } from 'node:child_process'
import { createHash } from 'node:crypto'
import { chmod, mkdir, mkdtemp, readdir, readFile, rename, rm, stat, writeFile } from 'node:fs/promises'
import { createServer } from 'node:http'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { promisify } from 'node:util'
import { afterEach, describe, expect, it } from 'vitest'
import { chooseOption, describeToolCall, launchCommand, Normaliser, publicAuthMethods, readSpec, recapFrom } from '../caboose-agentd.mjs'

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
    await run(box, 'sign-in', { agent: AGENT, methodId: 'stand-in-terminal' })
    expect(await signInState(box)).toMatchObject({ methodId: 'stand-in-terminal', status: 'succeeded' })
    expect(await readFile(join(box.state, 'signed-in'), 'utf8')).toBe('terminal')
    expect((await readFile(join(box.root, 'terminal.log'), 'utf8')).trim()).toBe(':100 none 1')
  })

  it('opens the terminal with the launch environment the host sends, as on Caboose Display', async () => {
    const box = await sandbox({ auth: true })
    await run(box, 'sign-in', { agent: AGENT, methodId: 'stand-in-terminal', env: { WAYLAND_DISPLAY: 'wayland-caboose-0', DISPLAY: ':110', 'bad name': 'x' } })
    expect(await signInState(box)).toMatchObject({ methodId: 'stand-in-terminal', status: 'succeeded' })
    expect((await readFile(join(box.root, 'terminal.log'), 'utf8')).trim()).toBe(':110 wayland-caboose-0 1')
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
})
