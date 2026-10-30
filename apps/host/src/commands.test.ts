import { execFileSync } from 'node:child_process'
import { mkdtemp, readdir, rm, stat } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { fileURLToPath } from 'node:url'
import { afterEach, expect, it, vi } from 'vitest'
import { AgentConflictError, AgentInputError, AgentNotFoundError } from './agents.js'
import { COMMAND_LIMITS, CommandStore, ComputerCommands, commandJob, commandTitle, decodeStream, parseCommandRequest, parseGuestResult, parseWait, type CommandHooks, type CommandRecord } from './commands.js'
import { commandNotification } from './push.js'

const ID = '0123456789abcdef0123456789abcdef'
const cleanup: Array<() => Promise<void>> = []
afterEach(async () => { for (const work of cleanup.splice(0)) await work() })

it('accepts a strictly shaped command request with bounded fields', () => {
  expect(parseCommandRequest({ script: 'echo hi' })).toEqual({ script: 'echo hi', inputs: [], cwd: null, timeout: 3600, wait: 0 })
  expect(parseCommandRequest({ id: ID, script: 'cat', stdin: 'x', inputs: ['clip.mp4', 'notes (2).txt'], cwd: 'Videos/New', timeout: 86_400, wait: 60 }))
    .toEqual({ id: ID, script: 'cat', stdin: 'x', inputs: ['clip.mp4', 'notes (2).txt'], cwd: 'Videos/New', timeout: 86_400, wait: 60 })
  expect(parseCommandRequest({ script: 'pwd', cwd: '' }).cwd).toBe('')
  expect(parseCommandRequest({ script: 'pwd', cwd: null }).cwd).toBeNull()
  expect(parseCommandRequest({ script: 'x'.repeat(COMMAND_LIMITS.scriptBytes) }).script).toHaveLength(COMMAND_LIMITS.scriptBytes)
  for (const body of [
    {}, { script: '' }, { script: '  \n' }, { script: 1 }, { script: 'a\0b' }, { script: '\ud800' },
    { script: 'é'.repeat(COMMAND_LIMITS.scriptBytes / 2 + 1) },
    { script: 'cat', stdin: 'x'.repeat(COMMAND_LIMITS.stdinBytes + 1) }, { script: 'cat', stdin: 3 },
    { script: 'ls', shell: '/bin/sh' }, { script: 'ls', id: 'ABC' }, { script: 'ls', id: ID.slice(1) },
    { script: 'ls', inputs: ['a.txt'] }, { script: 'ls', id: ID, inputs: ['../a'] }, { script: 'ls', id: ID, inputs: ['a/b'] },
    { script: 'ls', id: ID, inputs: ['.'] }, { script: 'ls', id: ID, inputs: ['a', 'a'] }, { script: 'ls', id: ID, inputs: ['a\nb'] },
    { script: 'ls', id: ID, inputs: ['.caboose-upload-1'] }, { script: 'ls', id: ID, inputs: 'a' },
    { script: 'ls', id: ID, inputs: Array.from({ length: 101 }, (_, index) => `f${index}`) },
    { script: 'ls', cwd: '/etc' }, { script: 'ls', cwd: '../x' }, { script: 'ls', cwd: 'a//b' }, { script: 'ls', cwd: 'a/./b' }, { script: 'ls', cwd: 'a/' },
    { script: 'ls', timeout: 0 }, { script: 'ls', timeout: 86_401 }, { script: 'ls', timeout: 1.5 }, { script: 'ls', timeout: '60' },
    { script: 'ls', wait: -1 }, { script: 'ls', wait: 61 },
  ] as Array<Record<string, unknown>>) expect(() => parseCommandRequest(body), JSON.stringify(body).slice(0, 80)).toThrow(AgentInputError)
  expect(parseWait(null)).toBe(0)
  expect(parseWait('25')).toBe(25)
  for (const value of ['', '61', '-1', '1.5', '100', 'x']) expect(() => parseWait(value)).toThrow(AgentInputError)
})

it('names commands by their first line and checks what the guest reports', () => {
  expect(commandTitle('#!/bin/bash\n\n  yt-dlp "$URL"  \nffmpeg')).toBe('yt-dlp "$URL"')
  expect(commandTitle('#!/bin/sh\n')).toBe('Command')
  expect(Array.from(commandTitle('x'.repeat(300)))).toHaveLength(100)
  const good = { status: 'failed', exitCode: 3, signal: null, error: null, truncated: { stdout: false, stderr: true }, outputs: ['a.mp4'], finishedAt: 1 }
  expect(parseGuestResult(good)).toEqual({ status: 'failed', exitCode: 3, signal: null, error: null, truncated: { stdout: false, stderr: true }, outputs: ['a.mp4'] })
  expect(parseGuestResult({ ...good, error: 'x'.repeat(900) }).error).toHaveLength(500)
  for (const change of [{ status: 'running' }, { exitCode: 256 }, { exitCode: -1 }, { signal: 'KILL; rm' }, { error: 1 }, { truncated: { stdout: 'no', stderr: false } },
    { outputs: ['../etc/passwd'] }, { outputs: ['/abs'] }, { outputs: ['a', 'a'] }, { outputs: Array.from({ length: 101 }, (_, index) => `f${index}`) }]) {
    expect(() => parseGuestResult({ ...good, ...change })).toThrow()
  }
  expect(() => parseGuestResult(null)).toThrow()
  expect(decodeStream(Buffer.from('héllo').toString('base64') + '\n')).toEqual({ text: 'héllo', truncated: false })
  const large = decodeStream(Buffer.alloc(COMMAND_LIMITS.outputBytes + 10, 97).toString('base64'))
  expect(large.truncated).toBe(true)
  expect(large.text).toHaveLength(COMMAND_LIMITS.outputBytes)
  expect(() => decodeStream('not base64!')).toThrow()
})

it('describes finished commands as jobs and as task notifications', () => {
  const record = finished({ status: 'succeeded', outputs: ['a.mp4', 'b.mp4'] })
  expect(commandJob(record)).toEqual({ id: ID, kind: 'command', title: 'ffmpeg -i in.mov out.mp4', status: 'succeeded', detail: 'Finished with 2 files' })
  expect(commandJob(finished({ status: 'failed', exitCode: 1 })).detail).toBe('Exited with code 1')
  expect(commandJob(finished({ status: 'failed', signal: 'SIGKILL' })).detail).toBe('Stopped by SIGKILL')
  expect(commandJob(finished({ status: 'timed-out' }))).toMatchObject({ status: 'failed', detail: 'Stopped after 3600 s' })
  expect(commandNotification(record)).toEqual({ kind: 'task', collapseId: `command-${ID}`, payload: {
    aps: { alert: { title: 'Command finished', body: 'ffmpeg -i in.mov out.mp4 · Finished with 2 files' }, 'thread-id': `command-${ID}`, sound: 'default' }, commandId: ID } })
  expect(commandNotification(finished({ status: 'timed-out' }))?.payload).toMatchObject({ aps: { alert: { title: 'Command timed out' } } })
  expect(commandNotification(finished({ status: 'cancelled' }))).toBeUndefined()
})

function finished(change: Partial<CommandRecord>): CommandRecord {
  return { id: ID, title: 'ffmpeg -i in.mov out.mp4', script: 'ffmpeg -i in.mov out.mp4', cwd: null, inputs: [], timeout: 3600, status: 'succeeded', exitCode: 0, signal: null, error: null,
    stdout: '', stderr: '', truncated: { stdout: false, stderr: false }, outputs: [], createdAt: new Date(0).toISOString(), finishedAt: new Date(1).toISOString(), ...change }
}

/** The guest runner, as the host sees it: one mode and one JSON argument per call. */
function fakeGuest() {
  const jobs = new Map<string, { state: 'running' | 'done'; result?: object; stdout?: string; stderr?: string }>()
  const calls: Array<{ command: string; args: string[]; mode: string; request: any }> = []
  const failures: Record<string, string> = {}
  const run = vi.fn(async (command: string, args: string[]) => {
    const python = command === '/usr/sbin/runuser' ? args.slice(3) : [command, ...args]
    expect(python.slice(0, 2)).toEqual(['/usr/bin/python3', '-c'])
    const mode = python[3]!, request = JSON.parse(python[4]!)
    calls.push({ command, args, mode, request })
    if (failures[mode]) throw new Error(`Guest command failed: ${failures[mode]}`)
    switch (mode) {
      case 'prepare': return '{}'
      case 'start': jobs.set(request.id, { state: 'running' }); return '{"pid": 7}'
      case 'poll': return JSON.stringify(Object.fromEntries(request.ids.map((id: string) => [id, jobs.get(id)?.state ?? 'gone'])))
      case 'result': return JSON.stringify(jobs.get(request.id)?.result)
      case 'read': return Buffer.from((jobs.get(request.id) as any)?.[request.stream] ?? '').toString('base64')
      case 'cancel': {
        const job = jobs.get(request.id)!
        Object.assign(job, { state: 'done', result: { status: 'cancelled', exitCode: null, signal: 'SIGTERM', error: null, truncated: { stdout: false, stderr: false }, outputs: [] } })
        return '{"finished": false}'
      }
    }
    throw new Error('unknown mode')
  })
  const finish = (id: string, result: object, streams: { stdout?: string; stderr?: string } = {}) => {
    Object.assign(jobs.get(id)!, { state: 'done', result: { exitCode: 0, signal: null, error: null, truncated: { stdout: false, stderr: false }, outputs: [], ...result }, ...streams })
  }
  return { guest: { run }, jobs, calls, failures, finish }
}

function harness(store = CommandStore.memory()) {
  const fake = fakeGuest()
  const files = new Map<string, string>()
  let leases = 0
  const progress = vi.fn<CommandHooks['progress']>()
  const wake = vi.fn(async () => {})
  const commands = new ComputerCommands(store, {
    guest: () => fake.guest,
    writeFile: async (relative, data) => { files.set(relative, data.toString()) },
    acquire: () => { leases++; let held = true; return () => { if (held) { held = false; leases-- } } },
    wake, progress,
  }, { pollMs: 5, longMs: 40 })
  cleanup.push(async () => commands.pause())
  return { commands, fake, files, progress, wake, leases: () => leases }
}

it('runs a command detached, holds a lease until it ends and returns its result to a waiting caller', async () => {
  const { commands, fake, files, progress, leases } = harness()
  const script = 'yt-dlp -o "$CABOOSE_OUT/%(title)s.%(ext)s" "$(cat)"'
  const record = await commands.start(parseCommandRequest({ id: ID, script, stdin: 'https://example.com/v', inputs: ['a.txt'], cwd: 'Videos', timeout: 600 }))
  expect(record).toMatchObject({ id: ID, status: 'running', title: script, cwd: 'Videos', inputs: ['a.txt'] })
  expect(files).toEqual(new Map([[`.caboose-jobs/cmd-${ID}/command.sh`, script], [`.caboose-jobs/cmd-${ID}/stdin`, 'https://example.com/v']]))
  // Only the start runs as the owner, through runuser; neither script nor stdin is an argument.
  expect(fake.calls.map(call => [call.command, call.mode])).toEqual([['/usr/bin/python3', 'prepare'], ['/usr/sbin/runuser', 'start']])
  expect(fake.calls[1]!.args.slice(0, 3)).toEqual(['-u', 'caboose', '--'])
  expect(fake.calls[1]!.request).toEqual({ id: ID, cwd: 'Videos', timeout: 600, stdin: true, inputs: ['a.txt'] })
  expect(fake.calls.some(call => call.args.some(arg => arg.includes('example.com')))).toBe(false)
  expect(leases()).toBe(1)
  expect(progress).toHaveBeenCalledWith(expect.objectContaining({ id: ID }), 'started', { waited: false, long: false })
  expect(commands.busy).toBe(1)

  const waiting = commands.wait(ID, 5)
  await vi.waitFor(() => expect(progress).toHaveBeenCalledWith(expect.anything(), 'long', { waited: true, long: true }))
  fake.finish(ID, { status: 'succeeded', outputs: ['Video.mp4'], truncated: { stdout: false, stderr: true } }, { stdout: 'done\n', stderr: 'progress' })
  const result = await waiting
  expect(result).toMatchObject({ status: 'succeeded', exitCode: 0, stdout: 'done\n', stderr: 'progress', outputs: ['Video.mp4'], truncated: { stdout: false, stderr: true } })
  expect(result.finishedAt).not.toBeNull()
  expect(leases()).toBe(0)
  expect(commands.busy).toBe(0)
  expect(progress).toHaveBeenLastCalledWith(expect.objectContaining({ status: 'succeeded' }), 'finished', { waited: true, long: true })
  expect(commands.get(ID).status).toBe('succeeded')
  await expect(commands.cancel(ID)).rejects.toThrow(AgentConflictError)
  await expect(commands.start(parseCommandRequest({ id: ID, script: 'ls' }))).rejects.toThrow(AgentConflictError)
  expect(() => commands.get('f'.repeat(32))).toThrow(AgentNotFoundError)
  expect(() => commands.get('../x')).toThrow(AgentNotFoundError)
})

it('returns a running command when the wait ends, and notifies nobody waiting when it finishes', async () => {
  const { commands, fake, progress } = harness()
  const { id } = await commands.start(parseCommandRequest({ script: 'sleep 1' }))
  expect(id).toMatch(/^[0-9a-f]{32}$/)
  expect((await commands.wait(id, 0)).status).toBe('running')
  const abort = new AbortController()
  const waiting = commands.wait(id, 30, abort.signal)
  abort.abort()
  expect((await waiting).status).toBe('running')
  fake.finish(id, { status: 'failed', exitCode: 2 })
  await vi.waitFor(() => expect(commands.get(id).status).toBe('failed'))
  expect(progress).toHaveBeenLastCalledWith(expect.objectContaining({ exitCode: 2 }), 'finished', { waited: false, long: false })
})

it('cancels, limits concurrent commands and fails commands whose supervisor vanished', async () => {
  const { commands, fake } = harness()
  const ids: string[] = []
  for (let index = 0; index < COMMAND_LIMITS.running; index++) ids.push((await commands.start(parseCommandRequest({ script: `sleep ${index}` }))).id)
  await expect(commands.start(parseCommandRequest({ script: 'one more' }))).rejects.toThrow(/already running/)
  await commands.cancel(ids[0]!)
  expect((await commands.wait(ids[0]!, 5)).status).toBe('cancelled')
  fake.jobs.delete(ids[1]!)
  await vi.waitFor(() => expect(commands.get(ids[1]!)).toMatchObject({ status: 'failed', error: 'The command stopped without a result.' }))
  await commands.computerRestarted()
  expect(commands.get(ids[2]!)).toMatchObject({ status: 'failed', error: 'Stopped when the computer restarted.' })
  expect(commands.busy).toBe(0)
})

it('does not mistake a command that is still starting for a vanished one', async () => {
  const { commands, fake } = harness()
  const first = await commands.start(parseCommandRequest({ script: 'sleep 600' }))
  let release!: () => void
  const gate = new Promise<void>(resolve => { release = resolve })
  const run = fake.guest.run.getMockImplementation()!
  fake.guest.run.mockImplementation(async (command, args) => {
    if (command === '/usr/sbin/runuser') await gate
    return run(command, args)
  })
  const starting = commands.start(parseCommandRequest({ id: ID, script: 'sleep 600' }))
  await vi.waitFor(() => expect(fake.calls.filter(call => call.mode === 'poll').length).toBeGreaterThan(2))
  expect(fake.calls.filter(call => call.mode === 'poll').every(call => !call.request.ids.includes(ID))).toBe(true)
  release()
  expect((await starting).status).toBe('running')
  expect(commands.get(first.id).status).toBe('running')
  await vi.waitFor(() => expect(fake.calls.some(call => call.mode === 'poll' && call.request.ids.includes(ID))).toBe(true))
  expect(commands.get(ID).status).toBe('running')
})

it('turns guest refusals into input and conflict errors without notifying', async () => {
  const { commands, fake, progress, leases } = harness()
  fake.failures.prepare = 'caboose-command conflict: a command with this id already exists'
  await expect(commands.start(parseCommandRequest({ id: ID, script: 'ls' }))).rejects.toThrow(AgentConflictError)
  delete fake.failures.prepare
  fake.failures.start = 'Traceback …\ncaboose-command input: input file not found: a.txt\n'
  await expect(commands.start(parseCommandRequest({ id: ID, script: 'ls', inputs: ['a.txt'] }))).rejects.toThrow(new AgentInputError('input file not found: a.txt'))
  expect(() => commands.get(ID)).toThrow(AgentNotFoundError)
  expect(commands.busy).toBe(0)
  expect(progress).not.toHaveBeenCalled()
  expect(leases()).toBe(0)
})

it('retains and collects a started command when its acknowledgement is lost', async () => {
  const { commands, fake, leases } = harness()
  const run = fake.guest.run.getMockImplementation()!
  fake.guest.run.mockImplementation(async (command, args) => {
    const result = await run(command, args)
    if (command === '/usr/sbin/runuser') throw new Error('transport closed after launch')
    return result
  })
  const record = await commands.start(parseCommandRequest({ id: ID, script: 'sleep 1' }))
  expect(record.status).toBe('running')
  expect(leases()).toBe(1)
  await commands.poll()
  expect(commands.get(ID).status).toBe('running')
  fake.finish(ID, { status: 'succeeded' }, { stdout: 'completed once' })
  await commands.poll()
  expect(commands.get(ID)).toMatchObject({ status: 'succeeded', stdout: 'completed once' })
  expect(leases()).toBe(0)
  expect(fake.calls.filter(call => call.mode === 'start')).toHaveLength(1)
})

it('fails a command whose result is malformed', async () => {
  const { commands, fake } = harness()
  const { id } = await commands.start(parseCommandRequest({ script: 'ls' }))
  fake.finish(id, { status: 'succeeded', outputs: ['../../etc/shadow'] })
  await vi.waitFor(() => expect(commands.get(id)).toMatchObject({ status: 'failed', error: 'The computer reported an invalid result.', outputs: [] }))
})

it('keeps results in private files across host restarts and finishes recovered commands', async () => {
  const dir = await mkdtemp(join(tmpdir(), 'caboose-commands-'))
  cleanup.push(() => rm(dir, { recursive: true, force: true }))
  const first = harness(await CommandStore.open(join(dir, 'commands')))
  const done = await first.commands.start(parseCommandRequest({ script: 'echo hi' }))
  first.fake.finish(done.id, { status: 'succeeded' }, { stdout: 'hi\n' })
  await vi.waitFor(() => expect(first.commands.get(done.id).status).toBe('succeeded'))
  const running = await first.commands.start(parseCommandRequest({ script: 'sleep 600' }))
  first.commands.pause()
  await new Promise(resolve => setTimeout(resolve, 50))
  expect((await stat(join(dir, 'commands', `${done.id}.json`))).mode & 0o777).toBe(0o600)

  const second = harness(await CommandStore.open(join(dir, 'commands')))
  expect(second.commands.get(done.id)).toMatchObject({ status: 'succeeded', stdout: 'hi\n' })
  expect(second.commands.list().map(record => record.id)).toEqual([running.id, done.id])
  second.fake.jobs.set(running.id, { state: 'running' })
  second.commands.recover()
  expect(second.leases()).toBe(1)
  expect(second.wake).toHaveBeenCalledOnce()
  second.commands.resume()
  second.fake.finish(running.id, { status: 'succeeded' })
  await vi.waitFor(() => expect(second.commands.get(running.id).status).toBe('succeeded'))
  expect(second.leases()).toBe(0)
  // It ran past the long-run delay before the restart, so its Live Activity is ended.
  expect(second.progress).toHaveBeenLastCalledWith(expect.objectContaining({ id: running.id }), 'finished', { waited: false, long: true })
})

it('keeps the 50 most recent finished commands for a week', async () => {
  const dir = await mkdtemp(join(tmpdir(), 'caboose-commands-'))
  cleanup.push(() => rm(dir, { recursive: true, force: true }))
  let now = Date.parse('2026-10-01T00:00:00Z')
  const store = await CommandStore.open(dir, () => now)
  const id = (index: number) => index.toString(16).padStart(32, '0')
  for (let index = 0; index < 55; index++) {
    const at = new Date(now + index * 1000).toISOString()
    await store.save(finished({ id: id(index), createdAt: at, finishedAt: at }))
  }
  await store.save(finished({ id: id(99), status: 'running', finishedAt: null, createdAt: new Date(now - 30 * 86_400_000).toISOString() }))
  await store.prune()
  expect(store.list()).toHaveLength(51)
  expect(store.get(id(4))).toBeUndefined()
  expect(store.get(id(5))).toBeDefined()
  expect((await readdir(dir)).filter(name => name.endsWith('.json'))).toHaveLength(51)
  now += 8 * 86_400_000
  await store.prune()
  expect(store.list().map(record => record.id)).toEqual([id(99)])
  expect((await CommandStore.open(dir, () => now)).list()).toHaveLength(1)
})

it('runs the guest runner against real files, a login shell and real processes', () => {
  const output = execFileSync('python3', [fileURLToPath(new URL('./guest-command-check.py', import.meta.url))], { encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'] })
  expect(output).toBe('')
}, 60_000)

function deferred() { let resolve!: () => void; const promise = new Promise<void>(done => { resolve = done }); return { promise, resolve } }

it('refuses active checkpoint work without pausing command completion or replaying it', async () => {
  const h = harness()
  const running = await h.commands.start(parseCommandRequest({ id: ID, script: 'echo completed' }))
  await expect(h.commands.quiesceForCheckpoint()).rejects.toThrow('running')
  expect(h.leases()).toBe(1)
  h.fake.finish(running.id, { status: 'succeeded' }, { stdout: 'completed' })
  await vi.waitFor(() => expect(h.commands.get(ID).status).toBe('succeeded'))
  const release = await h.commands.quiesceForCheckpoint()
  await expect(h.commands.start(parseCommandRequest({ script: 'blocked' }))).rejects.toThrow('checkpoint')
  h.commands.resume(); await h.commands.poll()
  release(); release()
  await expect(h.commands.start(parseCommandRequest({ id: ID, script: 'must not replay' }))).rejects.toThrow('already exists')
  expect(h.fake.calls.filter(call => call.mode === 'start')).toHaveLength(1)
})

it('waits for in-flight poll persistence even after the in-memory result becomes finished', async () => {
  const settings = await import('./settings.js')
  const dir = await mkdtemp(join(tmpdir(), 'command-drain-'))
  cleanup.push(() => rm(dir, { recursive:true,force:true }))
  const store = await CommandStore.open(dir), h = harness(store)
  await h.commands.start(parseCommandRequest({ id: ID, script: 'echo receipt' })); h.commands.pause()
  const entered = deferred(), write = deferred()
  const original = settings.writePrivateJson
  const spy = vi.spyOn(settings,'writePrivateJson').mockImplementationOnce(async (...args) => { entered.resolve(); await write.promise; await original(...args) })
  let release: (() => void) | undefined
  const poll = (async () => { h.fake.finish(ID, {status:'succeeded'},{stdout:'receipt'}); await h.commands.poll() })()
  try {
    await entered.promise
    expect(h.commands.busy).toBe(0)
    expect(store.persistenceStatus).toMatchObject({pendingWrites:1,error:null})
    let drained = false
    const hold = h.commands.quiesceForCheckpoint().then(value => { drained = true; return value })
    await Promise.resolve(); expect(drained).toBe(false)
    write.resolve(); await poll; release = await hold
    expect(store.persistenceStatus).toEqual({pendingWrites:0,error:null})
    expect((await CommandStore.open(dir)).get(ID)?.stdout).toBe('receipt')
  } finally { write.resolve(); await poll; release?.(); spy.mockRestore() }
})

it('keeps failed receipt persistence observable and refuses checkpoint after poll logs the error', async () => {
  const settings = await import('./settings.js')
  const dir = await mkdtemp(join(tmpdir(), 'command-write-failure-'))
  cleanup.push(() => rm(dir, {recursive:true,force:true}))
  const store = await CommandStore.open(dir), h = harness(store)
  await h.commands.start(parseCommandRequest({id:ID,script:'echo result'})); h.commands.pause()
  const failure = new Error('disk write refused')
  const spy = vi.spyOn(settings,'writePrivateJson').mockRejectedValueOnce(failure)
  const log = vi.spyOn(console,'error').mockImplementation(()=>{})
  try {
    h.fake.finish(ID,{status:'succeeded'},{stdout:'result'}); await h.commands.poll()
    expect(h.commands.busy).toBe(0)
    expect(store.persistenceStatus).toEqual({pendingWrites:0,error:failure})
    await expect(store.drain()).rejects.toThrow('durably persisted')
    await expect(h.commands.quiesceForCheckpoint()).rejects.toThrow('durably persisted')
    // A later successful write of this exact receipt repairs its persistence fault.
    await store.save(h.commands.get(ID)); await store.drain()
    const release = await h.commands.quiesceForCheckpoint(); release()
  } finally { spy.mockRestore(); log.mockRestore() }
})

it('retains the command freeze after a drain deadline until the real write settles', async () => {
  const settings = await import('./settings.js')
  const dir = await mkdtemp(join(tmpdir(),'command-drain-timeout-'))
  cleanup.push(()=>rm(dir,{recursive:true,force:true}))
  const store = await CommandStore.open(dir), h = harness(store), gate = deferred(), entered = deferred()
  const original = settings.writePrivateJson
  const spy = vi.spyOn(settings,'writePrivateJson').mockImplementationOnce(async (...args)=>{entered.resolve();await gate.promise;await original(...args)})
  const pending = store.save(finished({createdAt:new Date().toISOString(),finishedAt:new Date().toISOString()}))
  try {
    await entered.promise
    await expect(h.commands.quiesceForCheckpoint(10)).rejects.toThrow('deadline')
    await expect(h.commands.start(parseCommandRequest({script:'blocked'}))).rejects.toThrow('checkpoint')
    gate.resolve(); await pending; await store.drain()
    await vi.waitFor(async()=> { const release=await h.commands.quiesceForCheckpoint();release() })
  } finally {gate.resolve();await pending;spy.mockRestore()}
})
