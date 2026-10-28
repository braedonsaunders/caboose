import { mkdtemp, rm, writeFile } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { expect, it, vi } from 'vitest'
import type { DeskBackend } from '@braedonsaunders/appkit-desk'
import { createController } from './driver.js'

it('wakes, writes an Xpra token, parks with memory and restores using a DeskBackend', async () => {
  const root = await mkdtemp(join(tmpdir(), 'caboose-test-'))
  try {
    for (const file of ['base.raw', 'vmlinux', 'initrd']) await writeFile(join(root, file), '')
    const commands: string[] = []
    const restores: boolean[] = []
    const backend: DeskBackend = {
      async boot(plan, hooks) {
        restores.push(plan.snapshot.restoring)
        await hooks?.onRestored?.()
        return {
          deskId: plan.deskId,
          async request(command) {
            if (command.op === 'exec') commands.push([command.command, ...(command.args ?? [])].join(' '))
            return { exitCode: 0, signal: null, stdout: '', stderr: '', truncated: false }
          },
          subscribe: () => () => {},
          shutdown: async () => {},
          park: async () => {},
        }
      },
    }
    const network = vi.fn(async () => {})
    const controller = createController({ token: 'owner', host: '127.0.0.1', port: 7310, idleMs: 1000, imageRoot: root, memoryMb: 512, vcpus: 1, vmmPath: process.execPath }, { backend, network, deviceExists: () => true })
    const first = await controller.wake()
    expect(first.display.token).toMatch(/^[a-f0-9]{64}$/)
    expect(commands.some(command => command.includes('/run/caboose/xpra-token'))).toBe(true)
    await controller.park()
    const second = await controller.wake()
    expect(second.display.token).not.toBe(first.display.token)
    expect(restores).toEqual([false, true])
    expect(network).toHaveBeenCalledTimes(2)
    await controller.park()
  } finally { await rm(root, { recursive: true, force: true }) }
})
