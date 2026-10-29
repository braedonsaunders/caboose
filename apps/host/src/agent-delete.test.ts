import { afterEach, describe, expect, it } from 'vitest'
import { mkdtemp, mkdir, readFile, readdir, rm, symlink, writeFile } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { execFile } from 'node:child_process'
import { promisify } from 'node:util'
import { DELETE_TASK } from './agents.js'

const exec = promisify(execFile)
const roots: string[] = []
afterEach(async () => { await Promise.all(roots.splice(0).map(root => rm(root, { recursive: true, force: true }))) })
async function fixture() {
  const root = await mkdtemp(join(tmpdir(), 'caboose-delete-')); roots.push(root)
  const id = '11111111-1111-4111-8111-111111111111'
  const dir = join(root, id)
  await mkdir(dir)
  return { root, dir, id, remove: () => exec(process.execPath, ['-e', DELETE_TASK, dir]) }
}

describe('durable chat history deletion', () => {
  it('erases history, preserves generated files and attachments, and is retryable', async () => {
    const s = await fixture()
    await writeFile(join(s.dir, 'prompt.txt'), 'private prompt')
    await writeFile(join(s.dir, 'transcript.jsonl'), 'private conversation')
    await mkdir(join(s.dir, 'deliveries'))
    await writeFile(join(s.dir, 'deliveries', '000001.json'), 'delivered prompt')
    await writeFile(join(s.dir, '.delivery-input-11111111-1111-4111-8111-111111111111.json'), 'private reply')
    await mkdir(join(s.dir, 'inbox'))
    await writeFile(join(s.dir, 'inbox', 'reply.json'), 'queued message')
    await writeFile(join(s.dir, 'report.txt'), 'generated output')
    await mkdir(join(s.dir, 'attachments'))
    await writeFile(join(s.dir, 'attachments', 'input.txt'), 'user input')
    await writeFile(join(s.root, 'outside.txt'), 'outside output')
    await symlink(join(s.root, 'outside.txt'), join(s.dir, 'agent.log'))
    await s.remove()
    expect(await readdir(s.dir)).toEqual(['attachments', 'report.txt'])
    expect(await readFile(join(s.dir, 'report.txt'), 'utf8')).toBe('generated output')
    expect(await readFile(join(s.root, 'outside.txt'), 'utf8')).toBe('outside output')
    expect(await readdir(join(s.root, `.deleted-${s.id}`))).toEqual([])
    await s.remove()
    expect(await readFile(join(s.dir, 'attachments', 'input.txt'), 'utf8')).toBe('user input')
  })

  it('rejects a task directory symlink without touching its target', async () => {
    const s = await fixture()
    const target = join(s.root, 'other')
    await mkdir(target); await writeFile(join(target, 'prompt.txt'), 'keep')
    await rm(s.dir, { recursive: true }); await symlink(target, s.dir)
    await expect(s.remove()).rejects.toThrow('Invalid chat directory')
    expect(await readFile(join(target, 'prompt.txt'), 'utf8')).toBe('keep')
  })

  it.runIf(process.platform === 'linux')('refuses an unrelated live process', async () => {
    const s = await fixture()
    // The test process is not a runner. Its group identity must never authorize signalling.
    await writeFile(join(s.dir, 'pid'), String(process.pid))
    const stat = await readFile(`/proc/${process.pid}/stat`, 'utf8')
    const group = stat.slice(stat.lastIndexOf(')') + 2).split(' ')[2]!
    await writeFile(join(s.dir, 'pid'), group)
    await writeFile(join(s.dir, 'prompt.txt'), 'keep')
    await expect(s.remove()).rejects.toThrow('Cannot identify this chat runner')
    expect(await readFile(join(s.dir, 'prompt.txt'), 'utf8')).toBe('keep')
  })
})
