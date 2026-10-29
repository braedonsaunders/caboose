import { once } from 'node:events'
import { mkdtemp, mkdir, rm, writeFile } from 'node:fs/promises'
import { connect } from 'node:net'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { PassThrough } from 'node:stream'
import type { DeskBackend, DeskHandle, DeskHost } from '@braedonsaunders/appkit-desk'
import { expect, it, vi } from 'vitest'
import { config } from './config.js'
import { DISPLAY_ENV } from './display.test.js'
import { createController } from './driver.js'

it('relays native Mac guest ports only while awake and preserves the disk on park', async () => {
  const root = await mkdtemp(join(tmpdir(), 'caboose-native-test-'))
  let controller: ReturnType<typeof createController> | undefined
  try {
    for (const file of ['base.raw', 'vmlinux', 'initrd']) await writeFile(join(root, file), '')
    const commands: string[] = [], ports: number[] = []
    const desk = {
      exec: async (request: { command: string; args?: string[] }) => {
        commands.push([request.command, ...request.args ?? []].join(' '))
        return { exitCode: 0, stdout: request.command === '/bin/cat' ? DISPLAY_ENV : '', stderr: '', truncated: false }
      },
      connect: async (port: number) => { ports.push(port); return new PassThrough() },
      renewLease: () => {},
    } as unknown as DeskHandle
    const start = vi.fn(async (_options: unknown) => desk)
    const pause = vi.fn(async () => {})
    const resume = vi.fn(async () => desk)
    const host = {
      start, stats: () => ({}),
      canPause: () => true, pause, resume,
      suspend: async () => { await mkdir(join(root, 'overlays/owner.snapshot'), { recursive: true }) },
      destroy: async () => {},
    } as unknown as DeskHost
    const network = vi.fn(async () => {})
    controller = createController(config({ CABOOSE_IMAGE_ROOT: root, CABOOSE_VMM_PATH: process.execPath }), {
      desks: host, backend: { hypervisor: 'virtualization' } as DeskBackend, network,
    })
    await controller.wake('headless')
    expect(commands.some(command => command.includes('systemctl start') && command.includes('caboose-display.service'))).toBe(false)
    await controller.promote!()
    expect(commands.some(command => command.includes('caboose-display.service'))).toBe(true)
    expect(controller.canFreeze?.()).toBe(true)
    await controller.freeze!()
    await controller.thaw!()
    expect(pause).toHaveBeenCalledWith('owner')
    expect(resume).toHaveBeenCalledWith('owner')
    expect(network).not.toHaveBeenCalled()
    expect(start.mock.calls[0]?.[0]).not.toHaveProperty('network')
    expect(commands.some(command => command.includes('10.0.2.15/24'))).toBe(true)
    const endpoint = new URL(controller.displayUrl)
    expect(endpoint.hostname).toBe('127.0.0.1')
    const socket = connect(Number(endpoint.port), endpoint.hostname)
    await once(socket, 'connect')
    socket.write('native display bytes')
    expect(String((await once(socket, 'data'))[0])).toBe('native display bytes')
    expect(ports).toEqual([14600])
    const closed = once(socket, 'close')
    await controller.park()
    await closed
    expect(() => controller!.displayUrl).toThrow('not running')
    expect(controller.hasSavedState()).toBe(true)
    await controller.wake()
    expect(controller.fileService?.().url).toMatch(/^http:\/\/127\.0\.0\.1:\d+$/)
    await controller.park()
  } finally {
    await controller?.destroy?.()
    await rm(root, { recursive: true, force: true })
  }
})
