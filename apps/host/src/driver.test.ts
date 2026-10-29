import { existsSync } from 'node:fs'
import { mkdir, mkdtemp, readFile, rm, writeFile } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { expect, it, vi } from 'vitest'
import type { DeskBackend } from '@braedonsaunders/appkit-desk'
import { DISPLAY_ENV } from './display.test.js'
import { createController } from './driver.js'

it('resumes old resources but cold-restarts with saved settings and preserves the disk', async () => {
  const root = await mkdtemp(join(tmpdir(), 'caboose-test-'))
  try {
    const commands: string[] = []
    let failSync = false
    let supportsOwnerScope = true
    const restores: boolean[] = []
    const backend: DeskBackend = {
      async boot(plan, hooks) {
        expect(plan.initramfsPath).toBe(join(root, 'initrd'))
        restores.push(plan.snapshot.restoring)
        if (!plan.snapshot.restoring && plan.hypervisor === 'cloud-hypervisor') expect(plan.vmm.args).toContain('size=0,free_page_reporting=on')
        await hooks?.onRestored?.()
        return {
          deskId: plan.deskId,
          async request(command) {
            if (command.op === 'exec') commands.push([command.command, ...(command.args ?? [])].join(' '))
            if (command.op === 'exec' && command.command === '/usr/bin/test' && command.args?.[1] === '/usr/local/libexec/caboose-owner-run') return { exitCode: supportsOwnerScope ? 0 : 1, signal: null, stdout: '', stderr: '', truncated: false }
            if (command.op === 'exec' && command.command === '/bin/cat') return { exitCode: 0, signal: null, stdout: DISPLAY_ENV, stderr: '', truncated: false }
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
    const config = { vmFreePageReporting: true, token: 'owner', host: '127.0.0.1', port: 7310, idleMs: 1000, imageRoot: root, memoryMb: 512, vcpus: 1, vmmPath: process.execPath, runtime: 'microvm' as const, containerImage: '', baseImage: null, databaseUrl: null, containerName: '', containerHome: '', containerArgs: [], gpu: 'auto' as const, agentRegistryUrl: '', agentIdleMs: 1000, maxRunning: 4, publicUrl: null, mdns: false }
    const desired = { name: 'My computer', memoryMb: 512, vcpus: 1, idleMs: 60000, defaultAgent: null }
    const dependencies = { backend, network, deviceExists: () => true, snapshotSignature: { cpuSignature: async () => 'test-cpu', readSnapshotSignature: async () => 'test-cpu', writeSnapshotSignature: async () => {} }, settings: () => desired }
    const controller = createController(config, dependencies)
    // First-run provisioning happens after constructing the host pool.
    for (const file of ['base.raw', 'vmlinux', 'initrd']) await writeFile(join(root, file), '')
    expect(controller.activeResources()).toBeNull()
    const first = await controller.wake()
    await writeFile(join(root, 'overlays', 'owner.raw'), 'persistent user data')
    expect(first.display.token).toMatch(/^[a-f0-9]{64}$/)
    expect(first.computer.name).toBe('My computer')
    expect(commands.some(command => command.includes('/run/caboose/display-token'))).toBe(true)
    await controller.guest()!.run('/usr/sbin/runuser', ['-u', 'caboose', '--', '/bin/echo', 'first'])
    expect(commands).toContain('/usr/local/libexec/caboose-owner-run /bin/echo first')
    desired.memoryMb = 1024
    desired.vcpus = 2
    await controller.park()
    supportsOwnerScope = false
    expect(createController(config, dependencies).activeResources()).toEqual({ memoryMb: 512, vcpus: 1 })
    const second = await controller.wake()
    await controller.guest()!.run('/usr/sbin/runuser', ['-u', 'caboose', '--', '/bin/echo', 'second'])
    expect(commands).toContain('/usr/sbin/runuser -u caboose -- /bin/echo second')
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
      imageRoot: root, memoryMb: 2048, vcpus: 2, vmmPath: process.execPath, runtime: 'microvm', containerImage: '', baseImage: null, databaseUrl: null, containerName: '', containerHome: '', containerArgs: [], gpu: 'auto', agentRegistryUrl: '', agentIdleMs: 1000, maxRunning: 4, publicUrl: null, mdns: false })
    expect(controller.hasSavedState()).toBe(true)
    expect(controller.activeResources()).toBeNull()
  } finally { await rm(root, { recursive: true, force: true }) }
})

it('serves the owner display and starts the agent seat on demand', async () => {
  const root = await mkdtemp(join(tmpdir(), 'caboose-test-'))
  try {
    for (const file of ['base.raw', 'vmlinux', 'initrd']) await writeFile(join(root, file), '')
    const commands: string[] = []
    const backend: DeskBackend = {
      async boot(plan) {
        return {
          deskId: plan.deskId,
          async request(command) {
            if (command.op === 'exec') commands.push([command.command, ...(command.args ?? [])].join(' '))
            const stdout = command.op === 'exec' && command.command === '/bin/cat' ? DISPLAY_ENV : '[]'
            return { exitCode: 0, signal: null, stdout, stderr: '', truncated: false }
          },
          subscribe: () => () => {},
          shutdown: async () => {},
          park: async () => {},
        }
      },
    }
    const controller = createController({ token: 'owner', host: '127.0.0.1', port: 7310, idleMs: 1000, imageRoot: root, memoryMb: 512, vcpus: 1,
      vmmPath: process.execPath, runtime: 'microvm', containerImage: '', baseImage: null, databaseUrl: null, containerName: '', containerHome: '', containerArgs: [], gpu: 'auto', agentRegistryUrl: '', agentIdleMs: 1000, maxRunning: 4, publicUrl: null, mdns: false },
    { backend, network: async () => {}, deviceExists: () => true,
      snapshotSignature: { cpuSignature: async () => 'test-cpu', readSnapshotSignature: async () => 'test-cpu', writeSnapshotSignature: async () => {} } })
    const session = await controller.wake()
    expect(session.display.protocol).toBe('caboose-display')
    expect(controller.displayUrl).toMatch(/:14600\/$/)
    expect(commands.some(command => command.includes('caboose-display-ready 60') && command.endsWith('caboose-display.service 14600'))).toBe(true)
    expect(commands.some(command => command.includes('caboose-display-agent.service'))).toBe(false)
    expect(controller.agentDisplayUrl).toMatch(/:14601\/$/)
    await controller.ensureAgentSeat()
    expect(commands.at(-1)).toBe('/usr/local/libexec/caboose-agent-seat')
    await controller.apps()
    expect(commands.at(-1)).toContain('WAYLAND_DISPLAY=wayland-caboose-0')
    expect(commands.at(-1)).toContain('DISPLAY=:110')
    expect(commands.at(-1)).toContain('XAUTHORITY=/run/user/1000/caboose-xauth')
    await controller.launch('firefox.desktop', undefined, 'new-private-window')
    expect(commands.at(-1)).toMatch(/ action firefox\.desktop new-private-window$/)
    await controller.launch('firefox.desktop')
    expect(commands.at(-1)).toMatch(/ launch firefox\.desktop$/)
    await controller.park()
  } finally { await rm(root, { recursive: true, force: true }) }
})

it('runs another computer on its own disk and network, and deletes both with it', async () => {
  const root = await mkdtemp(join(tmpdir(), 'caboose-test-'))
  try {
    for (const file of ['base.raw', 'vmlinux', 'initrd']) await writeFile(join(root, file), '')
    const commands: string[] = []
    const plans: Array<{ deskId: string }> = []
    const backend: DeskBackend = {
      async boot(plan) {
        plans.push(plan)
        return {
          deskId: plan.deskId,
          async request(command) {
            if (command.op === 'exec') commands.push([command.command, ...(command.args ?? [])].join(' '))
            const stdout = command.op === 'exec' && command.command === '/bin/cat' ? DISPLAY_ENV : ''
            return { exitCode: 0, signal: null, stdout, stderr: '', truncated: false }
          },
          subscribe: () => () => {},
          shutdown: async () => {},
          park: async () => {},
        }
      },
    }
    const network = vi.fn(async () => {})
    const removeNetwork = vi.fn(async () => {})
    const controller = createController({ token: 'owner', host: '127.0.0.1', port: 7310, idleMs: 1000, imageRoot: root, memoryMb: 512, vcpus: 1,
      vmmPath: process.execPath, runtime: 'microvm', containerImage: '', baseImage: null, databaseUrl: null, containerName: '', containerHome: '', containerArgs: [], gpu: 'auto', agentRegistryUrl: '', agentIdleMs: 1000, maxRunning: 4, publicUrl: null, mdns: false },
    { identity: { id: 'c-0123456789', slot: 2 }, backend, network, removeNetwork, deviceExists: () => true,
      snapshotSignature: { cpuSignature: async () => 'test-cpu', readSnapshotSignature: async () => 'test-cpu', writeSnapshotSignature: async () => {} } })
    expect(controller.displayUrl).toBe('ws://192.0.2.10:14600/')
    expect(controller.fileService?.().url).toBe('http://192.0.2.10:14700')
    await controller.wake()
    expect(plans.map(plan => plan.deskId)).toEqual(['c-0123456789'])
    expect(commands.some(command => command.includes('ip addr replace 192.0.2.10/30') && command.includes('via 192.0.2.9'))).toBe(true)
    await writeFile(join(root, 'overlays', 'c-0123456789.raw'), 'their files')
    await writeFile(join(root, 'overlays', 'owner.raw'), 'the owner files')
    await controller.destroy!()
    expect(existsSync(join(root, 'overlays', 'c-0123456789.raw'))).toBe(false)
    expect(existsSync(join(root, 'overlays', 'c-0123456789.resources.json'))).toBe(false)
    expect(await readFile(join(root, 'overlays', 'owner.raw'), 'utf8')).toBe('the owner files')
    expect(removeNetwork).toHaveBeenCalledOnce()
    expect(controller.activeResources()).toBeNull()
  } finally { await rm(root, { recursive: true, force: true }) }
})

it('boots a new computer with the selected immutable system and keeps existing disks on the legacy image', async () => {
  const root = await mkdtemp(join(tmpdir(), 'caboose-split-driver-'))
  try {
    const split = join(root, 'version-one')
    await mkdir(split)
    for (const name of ['base.raw', 'vmlinux', 'initrd', 'system.erofs']) await writeFile(join(split, name), name)
    for (const name of ['base.raw', 'vmlinux', 'initrd']) await writeFile(join(root, name), name)
    const plans: any[] = []
    const backend: DeskBackend = { async boot(plan) {
      plans.push(plan)
      return { deskId: plan.deskId, async request(command) { return { exitCode: 0, signal: null, stdout: command.op === 'exec' && command.command === '/bin/cat' ? DISPLAY_ENV : '', stderr: '', truncated: false } }, subscribe: () => () => {}, shutdown: async () => {} }
    } }
    const config = { token: 'owner', host: '127.0.0.1', port: 7310, idleMs: 1000, imageRoot: root, memoryMb: 512, vcpus: 1, vmmPath: process.execPath, runtime: 'microvm' as const, containerImage: '', baseImage: null, databaseUrl: null, containerName: '', containerHome: '', containerArgs: [], gpu: 'auto' as const, agentRegistryUrl: '', agentIdleMs: 1000, maxRunning: 4, publicUrl: null, mdns: false }
    const dep = { backend, deviceExists: () => true, network: async () => {}, splitImage: split }
    const controller = createController(config, dep)
    await controller.wake()
    expect(plans[0].kernelPath).toBe(join(split, 'vmlinux'))
    expect(plans[0].vmm.args).toContain(`path=${join(split, 'system.erofs')},readonly=on,image_type=raw`)
    await controller.restart!()
    await mkdir(join(root, 'overlays'), { recursive: true })
    await writeFile(join(root, 'overlays', 'old.raw'), 'old disk')
    const old = createController(config, { ...dep, identity: { id: 'old', slot: 1 } })
    await old.wake()
    expect(plans.at(-1).kernelPath).toBe(join(root, 'vmlinux'))
    expect(plans.at(-1).vmm.args.some((arg: string) => arg.includes('system.erofs'))).toBe(false)
    await old.restart!()
    await controller.destroy!()
    await old.destroy!()
  } finally { await rm(root, { recursive: true, force: true }) }
})

it('attaches a host depot read-only and starts its guest mount', async () => {
  const root = await mkdtemp(join(tmpdir(), 'caboose-vm-depot-'))
  try {
    const depot = join(root, 'depot'); await mkdir(depot)
    for (const name of ['base.raw', 'vmlinux', 'initrd']) await writeFile(join(root, name), '')
    const starts: any[] = [], commands: string[] = []
    const desks = { stats: () => ({}), start: async (options: any) => { starts.push(options); return { exec: async ({ command, args }: any) => { commands.push([command, ...args].join(' ')); return { exitCode: 0, stdout: command === '/bin/cat' ? DISPLAY_ENV : '', stderr: '', truncated: false } }, renewLease: () => {} } }, destroy: async () => {} }
    const config = { token: 'owner', host: '127.0.0.1', port: 7310, idleMs: 1000, imageRoot: root, memoryMb: 512, vcpus: 1, vmmPath: process.execPath, runtime: 'microvm' as const, containerImage: '', baseImage: null, databaseUrl: null, containerName: '', containerHome: '', containerArgs: [], gpu: 'auto' as const, agentRegistryUrl: '', agentIdleMs: 1000, maxRunning: 4, publicUrl: null, mdns: false }
    const controller = createController(config, { desks: desks as any, backend: { hypervisor: 'cloud-hypervisor' } as any, deviceExists: () => true, network: async () => {}, removeNetwork: async () => {}, depotPath: depot })
    await controller.wake()
    expect(starts[0].shares).toEqual([{ tag: 'caboose-depot', path: depot, readOnly: true }])
    expect(commands).toContain('/bin/systemctl start var-lib-caboose-depot.mount')
    await controller.destroy!()
  } finally { await rm(root, { recursive: true, force: true }) }
})

it('probes Files over vsock and falls back when the guest does not support it', async () => {
  const { Duplex } = await import('node:stream')
  const { probeServiceVsock } = await import('./driver.js')
  const calls: unknown[] = []
  let socket: InstanceType<typeof Duplex> | undefined
  const desk = { connect: async (port: number, options: unknown) => {
    calls.push([port, options])
    socket = new Duplex({ read() {}, write(_chunk, _encoding, done) { this.push('HTTP/1.1 401 Unauthorized\r\n\r\n'); done() } })
    return socket
  } } as unknown as import('@braedonsaunders/appkit-desk').DeskHandle
  expect(await probeServiceVsock(desk)).toBe(true)
  expect(calls).toEqual([[14700, { transport: 'vsock' }]])
  expect(socket?.destroyed).toBe(true)
  const old = { connect: async () => { throw new Error('unavailable') } } as unknown as import('@braedonsaunders/appkit-desk').DeskHandle
  expect(await probeServiceVsock(old)).toBe(false)
  const hanging = { connect: async () => new Promise(() => {}) } as unknown as import('@braedonsaunders/appkit-desk').DeskHandle
  expect(await probeServiceVsock(hanging, 10)).toBe(false)
})

it('selects vsock for a guest that answers the service probe and closes relays on park', async () => {
  const { Duplex } = await import('node:stream')
  const root = await mkdtemp(join(tmpdir(), 'caboose-vsock-'))
  try {
    for (const file of ['base.raw', 'vmlinux', 'initrd']) await writeFile(join(root, file), '')
    const ports: number[] = []
    const backend: DeskBackend = { async boot(plan) { return {
      deskId: plan.deskId,
      async request(command) { return { exitCode: 0, signal: null, stdout: command.op === 'exec' && command.command === '/bin/cat' ? DISPLAY_ENV : '', stderr: '', truncated: false } },
      connect: async port => { ports.push(port); return new Duplex({ read() {}, write(_chunk, _encoding, done) { this.push('HTTP/1.1 401 Unauthorized\r\n\r\n'); done() } }) },
      subscribe: () => () => {}, shutdown: async () => {}, park: async () => {},
    } } }
    const config = { token: 'owner', host: '127.0.0.1', port: 7310, idleMs: 1000, imageRoot: root, memoryMb: 512, vcpus: 1, vmmPath: process.execPath, runtime: 'microvm' as const, containerImage: '', baseImage: null, databaseUrl: null, containerName: '', containerHome: '', containerArgs: [], gpu: 'auto' as const, agentRegistryUrl: '', agentIdleMs: 1000, maxRunning: 4, publicUrl: null, mdns: false }
    const controller = createController(config, { backend, network: async () => {}, deviceExists: () => true,
      snapshotSignature: { cpuSignature: async () => 'test-cpu', readSnapshotSignature: async () => 'test-cpu', writeSnapshotSignature: async () => {} } })
    await controller.wake()
    expect(ports).toEqual([14700])
    expect(controller.displayUrl).toMatch(/^ws:\/\/127\.0\.0\.1:\d+\/$/)
    const endpoint = controller.displayUrl
    await controller.park()
    expect(controller.displayUrl).toBe('ws://192.0.2.2:14600/')
    await expect(fetch(endpoint.replace('ws:', 'http:'))).rejects.toThrow()
  } finally { await rm(root, { recursive: true, force: true }) }
})
