import { execFile, spawn, type ChildProcessWithoutNullStreams } from 'node:child_process'
import { mkdtemp, mkdir, readFile, readdir, rm, symlink, utimes, writeFile } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join, resolve } from 'node:path'
import { createInterface } from 'node:readline'
import { promisify } from 'node:util'
import { afterEach, describe, expect, it, vi } from 'vitest'
import { AgentToolJournal } from './agent-tools-journal.js'
import { pollAgentTools } from './agent-tools-mailbox.js'
import type { AgentGuest } from './agents.js'

const task = { id: '11111111-1111-4111-8111-111111111111', profileId: '22222222-2222-4222-8222-222222222222', turn: 1 }
const exec = promisify(execFile)
let dir = ''
let child: ChildProcessWithoutNullStreams | undefined
async function setup(timeout = 3000) {
  dir = await mkdtemp(join(tmpdir(), 'caboose-mailbox-'))
  const agents = join(dir, 'Agents'), taskDir = join(agents, task.id)
  await mkdir(taskDir, { recursive: true }); await writeFile(join(taskDir, 'tool-turn'), '1')
  const guest: AgentGuest = { async run(_cmd, args) {
    const code = args[5]!.replace("'/home/caboose/Agents'", JSON.stringify(agents))
    const { stdout } = await exec('python3', ['-c', code, ...args.slice(6)], { maxBuffer: 2_000_000 })
    return stdout
  } }
  const dispatch = vi.fn(async () => ({ id: 'done' }))
  const journal = await AgentToolJournal.open(join(dir, 'journal.json'), dispatch)
  await journal.bindTask(task.id, task.profileId)
  child = spawn(process.execPath, [resolve('../../guest/agentd/agent-tools.mjs'), taskDir], { env: { ...process.env, CABOOSE_TOOL_TIMEOUT_MS: String(timeout) } })
  const lines = createInterface({ input: child.stdout })
  const messages: Record<number, unknown> = {}
  lines.on('line', line => { const msg = JSON.parse(line); messages[msg.id] = msg })
  const send = (id: number, method: string, params?: unknown) => child!.stdin.write(JSON.stringify({ jsonrpc: '2.0', id, method, params }) + '\n')
  const wait = async (id: number) => { for (let i = 0; i < 200; i++) { if (messages[id]) return messages[id] as any; await new Promise(r => setTimeout(r, 20)) } throw new Error('No MCP response') }
  return { guest, journal, dispatch, taskDir, send, wait }
}
afterEach(async () => {
  if (child) { child.stdin.end(); await new Promise<void>(resolveExit => { if (child!.exitCode !== null) resolveExit(); else child!.once('exit', () => resolveExit()) }); child = undefined }
  if (dir) await rm(dir, { recursive: true, force: true })
})
describe('profile tool mailbox', () => {
  it('serves MCP over real stdio and dispatches through the guest mailbox', async () => {
    const s = await setup()
    s.send(1, 'initialize', {}); expect((await s.wait(1)).result.capabilities.tools).toEqual({})
    s.send(2, 'tools/list')
    const tools = (await s.wait(2)).result.tools
    expect(tools.map((t: any) => t.name)).toContain('routine_get')
    const intervals = tools.find((t: any) => t.name === 'routine_create').inputSchema.properties.schedule.oneOf
    expect(intervals[0].properties.everyMs).toMatchObject({ minimum: 60000, maximum: Number.MAX_SAFE_INTEGER })
    s.send(3, 'tools/call', { name: 'routine_create', arguments: { name: 'Daily' } })
    const box = join(s.taskDir, 'tool-mailbox')
    for (let i = 0; i < 100; i++) { try { if ((await readdir(box)).some(x => x.endsWith('.request'))) break } catch {} await new Promise(r => setTimeout(r, 20)) }
    await pollAgentTools(s.guest, s.journal, [task], () => true)
    expect((await s.wait(3)).result.content[0].text).toContain('done')
    expect(s.dispatch).toHaveBeenCalledWith({ taskId: task.id, profileId: task.profileId, turn: 1 }, 'routine_create', { name: 'Daily' })
  })
  it('times out truthfully and cleans up requests', async () => {
    const s = await setup(150)
    s.send(1, 'tools/call', { name: 'memory_list', arguments: {} })
    const result = (await s.wait(1)).result
    expect(result.isError).toBe(true)
    expect(result.content[0].text).toContain('may have completed')
    expect((await readdir(join(s.taskDir, 'tool-mailbox')))).toEqual([])
  })
  it('cancels waiting and removes the request on stdio close', async () => {
    const s = await setup(10000)
    s.send(1, 'tools/call', { name: 'memory_list', arguments: {} })
    const box = join(s.taskDir, 'tool-mailbox')
    for (let i = 0; i < 100; i++) { try { if ((await readdir(box)).some(x => x.endsWith('.request'))) break } catch {} await new Promise(r => setTimeout(r, 20)) }
    child!.stdin.end()
    await new Promise<void>(resolveExit => child!.once('exit', () => resolveExit()))
    expect(await readdir(box)).toEqual([])
  })
  it('ignores stale turns, extra envelope fields, and symlinked requests', async () => {
    const s = await setup()
    const box = join(s.taskDir, 'tool-mailbox'); await mkdir(box)
    const id = '33333333-3333-4333-8333-333333333333'
    const request = join(box, `${id}.request`)
    await writeFile(request, JSON.stringify({ id, turn: 2, tool: 'memory_list', arguments: {} }))
    await pollAgentTools(s.guest, s.journal, [task], () => true)
    await writeFile(request, JSON.stringify({ id, turn: 1, tool: 'memory_list', arguments: {}, profileId: task.profileId }))
    await pollAgentTools(s.guest, s.journal, [task], () => true)
    await rm(request); await symlink('/etc/passwd', request)
    await pollAgentTools(s.guest, s.journal, [task], () => true)
    expect(s.dispatch).not.toHaveBeenCalled()
  })
  it('advances past abandoned requests and preserves future turns and live responses', async () => {
    const s = await setup()
    const box = join(s.taskDir, 'tool-mailbox'); await mkdir(box)
    const id = (n: number) => `00000000-0000-4000-8000-${String(n).padStart(12, '0')}`
    const request = (n: number, turn: number) => writeFile(join(box, `${id(n)}.request`), JSON.stringify({ id: id(n), turn, tool: 'memory_list', arguments: {} }))
    for (let n = 0; n < 40; n++) { await request(n, 0); await utimes(join(box, `${id(n)}.request`), 1, 1) }
    await request(40, 2)
    await request(41, 1)
    await request(42, 1); await writeFile(join(box, `${id(42)}.response`), 'live')
    await request(43, 1); await writeFile(join(box, `${id(43)}.response`), 'old')
    await utimes(join(box, `${id(43)}.request`), 1, 1); await utimes(join(box, `${id(43)}.response`), 1, 1)
    for (let n = 0; n < 8; n++) await pollAgentTools(s.guest, s.journal, [task], () => true)
    expect(s.dispatch).toHaveBeenCalledTimes(1)
    expect(await readFile(join(box, `${id(42)}.response`), 'utf8')).toBe('live')
    expect(await readFile(join(box, `${id(40)}.request`), 'utf8')).toContain('"turn":2')
    expect(await readdir(box)).not.toContain(`${id(43)}.request`)
    expect(await readdir(box)).not.toContain(`${id(43)}.response`)
  })
  it('makes progress for later tasks and subsequent polls', async () => {
    const s = await setup()
    const other = { ...task, id: 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa' }
    await s.journal.bindTask(other.id, other.profileId)
    const first = join(s.taskDir, 'tool-mailbox'); await mkdir(first)
    const second = join(dir, 'Agents', other.id, 'tool-mailbox'); await mkdir(second, { recursive: true })
    for (let n = 0; n < 25; n++) {
      const id = `10000000-0000-4000-8000-${String(n).padStart(12, '0')}`
      await writeFile(join(first, `${id}.request`), JSON.stringify({ id, turn: 1, tool: 'memory_list', arguments: {} }))
    }
    const id = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb'
    await writeFile(join(second, `${id}.request`), JSON.stringify({ id, turn: 1, tool: 'memory_list', arguments: {} }))
    for (let n = 0; n < 12; n++) await pollAgentTools(s.guest, s.journal, [task, other], () => true)
    expect(s.dispatch).toHaveBeenCalledTimes(26)
    expect(s.dispatch).toHaveBeenCalledWith({ taskId: other.id, profileId: other.profileId, turn: 1 }, 'memory_list', {})
  })
  it('keeps journal cursors independent past the scan limit with unreadable entries', async () => {
    const s = await setup()
    const small = { ...task, id: 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa' }
    const other = await AgentToolJournal.open(join(dir, 'other-journal.json'), vi.fn(async () => ({ id: 'done' })))
    await other.bindTask(small.id, small.profileId)
    await s.journal.bindTask(small.id, small.profileId)
    const box = join(s.taskDir, 'tool-mailbox'); await mkdir(box)
    await mkdir(join(dir, 'Agents', small.id, 'tool-mailbox'), { recursive: true })
    for (let n = 0; n < 300; n++) {
      const id = `20000000-0000-4000-8000-${String(n).padStart(12, '0')}`
      const path = join(box, `${id}.request`)
      if (n % 3 === 0) await symlink('/etc/passwd', path)
      else if (n % 3 === 1) await writeFile(path, 'x'.repeat(65537))
      else await writeFile(path, 'invalid')
    }
    const id = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb'
    await writeFile(join(box, `${id}.request`), JSON.stringify({ id, turn: 1, tool: 'memory_list', arguments: {} }))
    for (let n = 0; n < 4; n++) {
      await pollAgentTools(s.guest, s.journal, [task, small], () => true)
      await pollAgentTools(s.guest, other, [small], () => true)
    }
    expect(s.dispatch).toHaveBeenCalledTimes(1)
  })
  it('does not follow a symlinked mailbox or accept a different profile binding', async () => {
    const s = await setup()
    const outside = join(dir, 'outside'); await mkdir(outside)
    await writeFile(join(outside, '33333333-3333-4333-8333-333333333333.request'), JSON.stringify({ id: '33333333-3333-4333-8333-333333333333', turn: 1, tool: 'memory_list', arguments: {} }))
    await symlink(outside, join(s.taskDir, 'tool-mailbox'))
    await pollAgentTools(s.guest, s.journal, [task], () => true)
    await pollAgentTools(s.guest, s.journal, [{ ...task, profileId: task.id }], () => true)
    expect(s.dispatch).not.toHaveBeenCalled()
    expect(await readFile(join(outside, '33333333-3333-4333-8333-333333333333.request'), 'utf8')).toContain('memory_list')
  })
})
