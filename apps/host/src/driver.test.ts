import { mkdir, mkdtemp, readFile, rm, writeFile } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { expect, it, vi } from 'vitest'
import type { DeskBackend } from '@braedonsaunders/appkit-desk'
import { createController } from './driver.js'

it('resumes old resources but cold-restarts with saved settings and preserves the disk', async () => {
  const root = await mkdtemp(join(tmpdir(), 'caboose-test-'))
  try {
    for (const file of ['base.raw', 'vmlinux', 'initrd']) await writeFile(join(root, file), '')
    const commands: string[] = []
    let failSync = false
    const restores: boolean[] = []
    const backend: DeskBackend = {
      async boot(plan, hooks) {
        restores.push(plan.snapshot.restoring)
        await hooks?.onRestored?.()
        return {
          deskId: plan.deskId,
          async request(command) {
            if (command.op === 'exec') commands.push([command.command, ...(command.args ?? [])].join(' '))
            if (failSync && command.op === 'exec' && command.command === '/bin/sync') {
              return { exitCode: 1, signal: null, stdout: '', stderr: 'guest is unresponsive', truncated: false }
            }
            return { exitCode: 0, signal: null, stdout: '', stderr: '', truncated: false }
          },
          subscribe: () => () => {},
          shutdown: async () => {},
          park: async () => {},
        }
      },
    }
    const network = vi.fn(async () => {})
    const config = { token: 'owner', host: '127.0.0.1', port: 7310, idleMs: 1000, imageRoot: root, memoryMb: 512, vcpus: 1, vmmPath: process.execPath, runtime: 'microvm' as const, containerImage: '', containerName: '', containerHome: '', containerArgs: [], gpu: 'auto' as const }
    const desired = { name: 'My computer', memoryMb: 512, vcpus: 1, idleMs: 60000 }
    const dependencies = { backend, network, deviceExists: () => true, settings: () => desired }
    const controller = createController(config, dependencies)
    expect(controller.activeResources()).toBeNull()
    const first = await controller.wake()
    await writeFile(join(root, 'overlays', 'owner.raw'), 'persistent user data')
    expect(first.display.token).toMatch(/^[a-f0-9]{64}$/)
    expect(first.computer.name).toBe('My computer')
    expect(commands.some(command => command.includes('/run/caboose/xpra-token'))).toBe(true)
    desired.memoryMb = 1024
    desired.vcpus = 2
    await controller.park()
    expect(createController(config, dependencies).activeResources()).toEqual({ memoryMb: 512, vcpus: 1 })
    const second = await controller.wake()
    expect(second.computer.memoryMb).toBe(512)
    expect(controller.activeResources()).toEqual({ memoryMb: 512, vcpus: 1 })
    expect(second.display.token).not.toBe(first.display.token)
    expect(restores).toEqual([false, true])
    expect(network).toHaveBeenCalledTimes(2)
    const restarted = await controller.restart!()
    expect(restarted.computer).toMatchObject({ memoryMb: 1024, vcpus: 2 })
    expect(controller.activeResources()).toEqual({ memoryMb: 1024, vcpus: 2 })
    expect(restores).toEqual([false, true, false])
    expect(await readFile(join(root, 'overlays', 'owner.raw'), 'utf8')).toBe('persistent user data')
    failSync = true
    const recovered = await controller.restart!()
    expect(recovered.state).toBe('running')
    expect(restores).toEqual([false, true, false, false])
    expect(controller.lastError?.()).toContain('without confirming a disk flush')
    expect(await readFile(join(root, 'overlays', 'owner.raw'), 'utf8')).toBe('persistent user data')
    await controller.park()
  } finally { await rm(root, { recursive: true, force: true }) }
})

it('reports a legacy snapshot as having unknown active resources', async () => {
  const root = await mkdtemp(join(tmpdir(), 'caboose-test-'))
  try {
    await mkdir(join(root, 'overlays', 'owner.snapshot'), { recursive: true })
    const controller = createController({ token: 'owner', host: '127.0.0.1', port: 7310, idleMs: 1000,
      imageRoot: root, memoryMb: 2048, vcpus: 2, vmmPath: process.execPath, runtime: 'microvm', containerImage: '', containerName: '', containerHome: '', containerArgs: [], gpu: 'auto' })
    expect(controller.hasSavedState()).toBe(true)
    expect(controller.activeResources()).toBeNull()
  } finally { await rm(root, { recursive: true, force: true }) }
})
