import { execFileSync } from 'node:child_process'
import { describe, expect, it } from 'vitest'
import { EXEC_WRAPPER, HostExecInputError, encodeCommand, execute, parseExec, parseFileTarget, parseWrapped, writeFile } from './host-exec.js'

const gnuBase64 = (() => { try { execFileSync('base64', ['-w0'], { input: '' }); return true } catch { return false } })()

describe('the operator\'s root access to a computer', () => {
  it('takes an absolute command, string arguments and a bounded time limit', () => {
    expect(parseExec({ command: '/bin/true' })).toEqual({ command: '/bin/true', args: [], timeoutMs: 60_000 })
    expect(parseExec({ command: '/usr/bin/tar', args: ['-xf', '/var/tmp/r.tar'], timeoutMs: 600_000 }).args).toEqual(['-xf', '/var/tmp/r.tar'])
    for (const bad of [{ command: 'tar' }, { command: '/bin/true', args: [1] }, { command: '/bin/true', timeoutMs: 10 }, { command: '/bin/true', shell: true }, null])
      expect(() => parseExec(bad)).toThrow(HostExecInputError)
  })

  it('reads the exit status and standard error from the wrapper\'s last line', () => {
    const stderr = Buffer.from('tar: refused\n').toString('base64')
    expect(parseWrapped(`listing\nmore\n\x1e2 ${stderr}`)).toEqual({ exitCode: 2, stdout: 'listing\nmore', stderr: 'tar: refused\n' })
    expect(parseWrapped('\n\x1e0 ')).toEqual({ exitCode: 0, stdout: '', stderr: '' })
    expect(() => parseWrapped('no status')).toThrow('exit status')
  })

  it.skipIf(!gnuBase64)('wraps a real command: its output, status and errors come back apart', async () => {
    const guest = { run: async (command: string, args: string[]) => execFileSync(command, args, { encoding: 'utf8' }), ownerEnv: [] }
    const result = await execute(guest as never, '/bin/sh', ['-c', 'echo out; echo err >&2; exit 3'], 5000)
    expect(result).toEqual({ exitCode: 3, stdout: 'out\n', stderr: 'err\n' })
  })

  it.skipIf(!gnuBase64 || process.platform !== 'linux')('keeps a command\'s arguments off every live process but the command itself', async () => {
    const guest = { run: async (command: string, args: string[]) => execFileSync(command, args, { encoding: 'utf8' }), ownerEnv: [] }
    // pgrep never matches itself: nothing else may carry the pattern.
    expect((await execute(guest as never, '/usr/bin/pgrep', ['-f', 'caboose-no-such-process-4f1c'], 5000)).exitCode).toBe(1)
    expect(EXEC_WRAPPER).toContain('os.execvp')

  it('writes a file in chunks beside its target, then renames it into place', async () => {
    const runs: string[][] = []
    const guest = { run: async (command: string, args: string[]) => { runs.push([command, ...args]); return '' }, ownerEnv: [] }
    const data = Buffer.alloc(100_000, 7)
    await writeFile(guest as never, '/var/tmp/release.tar', '0600', data)
    expect(runs[0]!.slice(-2)).toEqual(['/var/tmp/release.tar.caboose-upload', '0600'])
    const chunks = runs.filter(run => run[2]?.includes('base64 -d')).map(run => run.at(-1)!)
    expect(Buffer.from(chunks.join(''), 'base64').equals(data)).toBe(true)
    expect(chunks.every(chunk => chunk.length % 4 === 0 || chunk === chunks.at(-1))).toBe(true)
    expect(runs.at(-1)).toEqual(['/bin/mv', '-f', '--', '/var/tmp/release.tar.caboose-upload', '/var/tmp/release.tar'])
  })

  it('hands the command over as one base64 argument, NUL-separated', () => {
    expect(Buffer.from(encodeCommand('/usr/bin/pgrep', ['-f', 'MCC|x y']), 'base64').toString()).toBe('/usr/bin/pgrep\0-f\0MCC|x y')
  })

  it('takes an absolute file path and an octal mode', () => {
    expect(parseFileTarget(new URLSearchParams('path=/var/tmp/x&mode=0644'))).toEqual({ path: '/var/tmp/x', mode: '0644' })
    expect(parseFileTarget(new URLSearchParams('path=/var/tmp/x')).mode).toBe('0600')
    for (const bad of ['path=x', 'path=/a/../b', 'path=/a/', 'path=/a&mode=rw'])
      expect(() => parseFileTarget(new URLSearchParams(bad))).toThrow(HostExecInputError)
  })
})
