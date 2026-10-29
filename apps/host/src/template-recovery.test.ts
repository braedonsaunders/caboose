import { execFile } from 'node:child_process'
import { mkdtemp, mkdir, readFile, rm, writeFile } from 'node:fs/promises'
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
