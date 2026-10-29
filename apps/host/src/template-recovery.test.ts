import { execFile, spawn } from 'node:child_process'
import { chmod, mkdtemp, mkdir, readFile, rm, writeFile } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { promisify } from 'node:util'
import { expect, it } from 'vitest'

const exec = promisify(execFile)
it('refuses source recovery without a valid private receipt', async () => {
  const root = await mkdtemp(join(tmpdir(), 'template-recovery-'))
  try {
    const id = 'a'.repeat(64), directory = join(root, 'templates', id)
    await mkdir(directory, { recursive: true })
    const script = new URL('../scripts/recover-template-source.sh', import.meta.url).pathname
    await expect(exec('bash', [script, root, id])).rejects.toThrow()
    await writeFile(join(directory, '.build.json'), JSON.stringify({ version: 1, tap: 'not-a-tap', runtime: '/elsewhere' }))
    await expect(exec('bash', [script, root, id])).rejects.toThrow()
    expect(await readFile(join(directory, '.build.json'), 'utf8')).toContain('not-a-tap')
  } finally { await rm(root, { recursive: true, force: true }) }
})

it('never treats a pre-ownership receipt as permission to touch a TAP', async () => {
  const root = await mkdtemp(join(tmpdir(), 'template-recovery-owner-'))
  try {
    const id = 'b'.repeat(64), directory = join(root, 'templates', id), bin = join(root, 'bin')
    await mkdir(directory, { recursive: true }); await mkdir(bin)
    // Run only the unprivileged preflight on developer machines; no networking
    // command can be reached without the required ownership marker.
    await writeFile(join(bin, 'id'), '#!/bin/sh\nprintf "0\n"\n'); await chmod(join(bin, 'id'), 0o755)
    await writeFile(join(directory, '.build.json'), JSON.stringify({ version: 1, tap: 'dsk123456789', runtime: join(root, 'runtime', 'tpl-test') }))
    const script = new URL('../scripts/recover-template-source.sh', import.meta.url).pathname
    await expect(exec('bash', [script, root, id], { env: { ...process.env, PATH: `${bin}:${process.env.PATH}` } })).rejects.toMatchObject({ stderr: expect.stringContaining('TAP ownership was not committed') })
    expect(await readFile(join(directory, '.build.json'), 'utf8')).toContain('dsk123456789')
  } finally { await rm(root, { recursive: true, force: true }) }
})

it('refuses recovery while the image-root host lock is held', async () => {
  const root = await mkdtemp(join(tmpdir(), 'template-recovery-lock-'))
  const holder = spawn('python3', ['-c', 'import fcntl,sys; f=open(sys.argv[1],"w"); fcntl.flock(f,fcntl.LOCK_EX); print("locked",flush=True); sys.stdin.read()', join(root, '.host.lock')], { stdio: ['pipe', 'pipe', 'pipe'] })
  try {
    await new Promise<void>((resolve, reject) => { holder.stdout.once('data', () => resolve()); holder.once('error', reject) })
    const script = new URL('../scripts/recover-template-source.sh', import.meta.url).pathname
    await expect(exec('bash', [script, root, 'c'.repeat(64)])).rejects.toMatchObject({ stderr: expect.stringContaining('locked by a host or VM') })
  } finally {
    holder.stdin.end()
    await new Promise<void>(resolve => holder.once('exit', () => resolve()))
    await rm(root, { recursive: true, force: true })
  }
})
