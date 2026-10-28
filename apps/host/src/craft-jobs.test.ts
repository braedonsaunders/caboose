import { expect, it, vi } from 'vitest'
import { parseCraftRequest, runCraft } from './craft-jobs.js'

const job = '0123456789abcdef0123456789abcdef'
it('accepts only whitelisted operations, input names, counts and formats', () => {
  expect(parseCraftRequest('pdfcraft', { job, inputs: ['input-0.pdf', 'input-1.pdf'], format: 'pdf' })).toEqual({ job, inputs: ['input-0.pdf', 'input-1.pdf'], format: 'pdf' })
  for (const [app, body] of [
    ['gimp', { job, inputs: ['input-0.png'], format: 'png' }],
    ['photocraft', { job, inputs: ['../input-0.png'], format: 'png' }],
    ['photocraft', { job, inputs: ['input-0.png'], format: 'exe' }],
    ['pdfcraft', { job, inputs: ['input-0.pdf'], format: 'pdf' }],
    ['filmcraft', { job, inputs: ['input-0.mp4'], format: 'mp4' }],
    ['lightcraft', { job, inputs: ['input-0.jpg'], format: 'jpg', command: 'arbitrary' }],
  ] as Array<[string, Record<string, unknown>]>) expect(() => parseCraftRequest(app, body)).toThrow()
})
it('runs a catalog CLI only when installed and rejects output outside the job', async () => {
  const input = parseCraftRequest('photocraft', { job, inputs: ['input-0.png'], format: 'jpg' })
  const run = vi.fn(async (_command: string, _args: string[]) => JSON.stringify({ outputs: [`.caboose-jobs/${job}/output-0.jpg`] }))
  expect(await runCraft({ run }, 'photocraft', input, true)).toEqual({ outputs: [`.caboose-jobs/${job}/output-0.jpg`], warnings: [] })
  expect(run.mock.calls[0]?.[0]).toBe('/usr/bin/python3')
  await expect(runCraft({ run }, 'photocraft', input, false)).rejects.toThrow('not installed')
  run.mockResolvedValueOnce(JSON.stringify({ outputs: ['../../elsewhere'] }))
  await expect(runCraft({ run }, 'photocraft', input, true)).rejects.toThrow('Invalid job output')
})

it('validates the guest runner against real files and fixed argument vectors', async () => {
  const { execFileSync } = await import('node:child_process')
  const { fileURLToPath } = await import('node:url')
  const output = execFileSync('python3', [fileURLToPath(new URL('./guest-craft-check.py', import.meta.url))], { encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'] })
  expect(output).toBe('')
})
