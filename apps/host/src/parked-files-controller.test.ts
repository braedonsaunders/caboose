import { mkdtemp, rm } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { expect, it, vi } from 'vitest'
import type { DeskMachine } from '@braedonsaunders/appkit-desk'
import { ParkedFilesController } from './parked-files-controller.js'
import { ParkedFilesJournal } from './parked-files-journal.js'

it('publishes only after durable park callback and completed suspend', async () => {
  const root = await mkdtemp(join(tmpdir(), 'parked-controller-'))
  try {
    const journal = new ParkedFilesJournal(join(root, 'intent'))
    const calls: string[] = []
    const machine = { request: async (request: { args: string[] }) => {
      const operation = request.args[1]!
      calls.push(operation)
      if (operation === 'freeze') expect(await journal.read()).toMatchObject({ version: 2, homeDevice: 123 })
      return { exitCode: 0, signal: null, stdout: operation === 'prepare' ? JSON.stringify({ branches: [{ path: '/user.slice', frozen: false }], homeDevice: 123 }) : '', stderr: '', truncated: false }
    } } as unknown as DeskMachine
    const stage = vi.fn(async () => { calls.push('stage'); return { directory: '/stage', image: '/stage/disk' } })
    const discard = vi.fn(async () => {})
    const publish = vi.fn(async () => { calls.push('publish') })
    const controller = new ParkedFilesController(journal, stage, discard, publish)
    expect(await controller.park(async hooks => {
      await hooks.beforePark(machine)
      await hooks.onPaused()
      await hooks.onParked('/snapshot')
      calls.push('suspend-return')
    }, () => true)).toBe(true)
    expect(calls).toEqual(['prepare', 'freeze', 'stage', 'suspend-return', 'publish'])
    expect(discard).not.toHaveBeenCalled()
  } finally { await rm(root, { recursive: true, force: true }) }
})

it('discards a staged clone when suspend fails or no completion arrives', async () => {
  for (const mode of ['failed', 'missing', 'cancelled', 'wake'] as const) {
    const root = await mkdtemp(join(tmpdir(), 'parked-controller-'))
    try {
      const journal = new ParkedFilesJournal(join(root, 'intent'))
      const machine = { request: async (request: { args: string[] }) => ({ exitCode: 0, signal: null, stdout: request.args[1] === 'prepare' ? '{"branches":[],"homeDevice":123}' : '', stderr: '', truncated: false }) } as unknown as DeskMachine
      const discard = vi.fn(async () => {})
      const publish = vi.fn(async () => {})
      let current = true
      const controller = new ParkedFilesController(journal, async () => ({ directory: '/stage', image: '/stage/disk' }), discard, publish)
      const attempt = controller.park(async hooks => {
        await hooks.beforePark(machine)
        await hooks.onPaused()
        if (mode === 'failed') throw new Error('suspend failed')
        if (mode === 'cancelled') hooks.onPausedError(new Error('cancelled'))
        if (mode === 'wake') { await hooks.onParked('/snapshot'); current = false }
      }, () => current)
      if (mode === 'failed') await expect(attempt).rejects.toThrow('suspend failed')
      else expect(await attempt).toBe(false)
      expect(discard).toHaveBeenCalledOnce()
      expect(publish).not.toHaveBeenCalled()
      expect(await journal.read()).toMatchObject({ version: 2 })
    } finally { await rm(root, { recursive: true, force: true }) }
  }
})
