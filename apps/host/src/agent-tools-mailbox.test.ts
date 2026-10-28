import { execFile, spawn, type ChildProcessWithoutNullStreams } from 'node:child_process'
import { mkdtemp, mkdir, readFile, readdir, rm, symlink, writeFile } from 'node:fs/promises'
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
    s.send(2, 'tools/list'); expect((await s.wait(2)).result.tools.map((t: any) => t.name)).toContain('routine_get')
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
