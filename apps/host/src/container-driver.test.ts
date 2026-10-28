import { describe, expect, it } from 'vitest'
import { config } from './config.js'
import { createContainerController, detectGpu, gpuArgs, type Docker } from './container-driver.js'
import { DISPLAY_ENV } from './display.test.js'

function fakeDocker(initial: 'missing' | 'running' | 'paused' | 'exited') {
  let status = initial
  const calls: string[][] = []
  const docker: Docker = async args => {
    calls.push(args)
    switch (args[0]) {
      case 'inspect':
        if (status === 'missing') throw new Error('No such object')
        if (args.includes('{{json .Config.Labels}}')) return '{"caboose.memory-mb":"4096","caboose.vcpus":"2"}'
        return `${status}\n`
      case 'run': status = 'running'; return 'id\n'
      case 'start': case 'unpause': status = 'running'; return ''
      case 'pause': status = 'paused'; return ''
      case 'rm': status = 'missing'; return ''
      case 'network': return ''
      case 'exec':
        if (args.includes('list')) return '[]'
        if (args.includes('/run/caboose/display.env')) return DISPLAY_ENV
        return ''
      default: return ''
    }
  }
  return { docker, calls }
}

const env = {
  CABOOSE_OWNER_TOKEN: 'x', CABOOSE_RUNTIME: 'container', CABOOSE_MEMORY_MB: '6144', CABOOSE_VCPUS: '4',
  CABOOSE_CONTAINER_IMAGE: 'caboose-computer:gpu', CABOOSE_CONTAINER_HOME: '/srv/caboose/home', CABOOSE_CONTAINER_ARGS: '--security-opt seccomp=unconfined',
}
const settings = config(env)

describe('createContainerController', () => {
  it('creates the computer with the GPU, its home and loopback-only displays, then starts the session', async () => {
    const fake = fakeDocker('missing')
    const controller = createContainerController(settings, { fence: async () => {}, docker: fake.docker, exists: path => path === '/dev/dxg' })
    const session = await controller.wake()
    expect(session.display.token).toMatch(/^[0-9a-f]{64}$/)
    const run = fake.calls.find(call => call[0] === 'run')!
    expect(run).toEqual(expect.arrayContaining(['--device', '/dev/dxg', 'CABOOSE_GPU=wsl', '-v', '/srv/caboose/home:/home/caboose', '--memory', '6144m', '--cpus', '4',
      '-p', '127.0.0.1:14500:14500', '--security-opt', 'seccomp=unconfined', 'caboose-computer:gpu']))
    expect(run.at(-1)).toBe('caboose-computer:gpu')
    const execs = fake.calls.filter(call => call[0] === 'exec').map(call => call.slice(4).join(' '))
    expect(execs[0]).toContain('/run/caboose/xpra-token')
    expect(execs).toEqual(expect.arrayContaining(['/usr/local/bin/caboose-session start', '/usr/local/bin/caboose-session ready :100']))
    expect(controller.guest()).toBeDefined()
  })

  it('starts caboose-display instead of Xpra :100 when configured, with its launch environment', async () => {
    const fake = fakeDocker('missing')
    const controller = createContainerController(config({ ...env, CABOOSE_DISPLAY: 'caboose' }), { fence: async () => {}, docker: fake.docker, exists: () => false })
    const session = await controller.wake()
    expect(session.display.protocol).toBe('caboose-display')
    expect(controller.displayUrl).toBe('ws://127.0.0.1:14600/')
    expect(fake.calls.find(call => call[0] === 'run')).toEqual(expect.arrayContaining(['-p', '127.0.0.1:14600:14600']))
    const execs = fake.calls.filter(call => call[0] === 'exec').map(call => call.slice(4).join(' '))
    expect(execs).toEqual(expect.arrayContaining(['/usr/local/bin/caboose-session start-display', '/usr/local/bin/caboose-session ready-display']))
    expect(execs).not.toContain('/usr/local/bin/caboose-session start')
    await controller.apps()
    expect(fake.calls.at(-1)).toEqual(expect.arrayContaining(['WAYLAND_DISPLAY=wayland-caboose-0', 'DISPLAY=:110',
      'XAUTHORITY=/run/user/1000/caboose-xauth', 'QT_QPA_PLATFORM=wayland;xcb']))
  })

  it('reads the display protocol from CABOOSE_DISPLAY, Xpra by default', () => {
    expect(config(env).display).toBe('xpra-ws')
    expect(config({ ...env, CABOOSE_DISPLAY: 'xpra' }).display).toBe('xpra-ws')
    expect(config({ ...env, CABOOSE_DISPLAY: 'caboose' }).display).toBe('caboose-display')
    expect(() => config({ ...env, CABOOSE_DISPLAY: 'vnc' })).toThrow('CABOOSE_DISPLAY')
  })

  it('parks by freezing and resumes with the same display token', async () => {
    const fake = fakeDocker('missing')
    const controller = createContainerController(settings, { fence: async () => {}, docker: fake.docker, exists: () => false })
    const first = await controller.wake()
    await controller.park()
    expect(fake.calls.at(-1)).toEqual(['pause', 'caboose-owner'])
    expect(controller.guest()).toBeUndefined()
    const second = await controller.wake()
    expect(fake.calls.some(call => call[0] === 'unpause')).toBe(true)
    expect(second.display.token).toBe(first.display.token)
    expect(fake.calls.filter(call => call[0] === 'run')).toHaveLength(1)
  })

  it('starts a stopped computer instead of recreating it', async () => {
    const fake = fakeDocker('exited')
    const controller = createContainerController(settings, { fence: async () => {}, docker: fake.docker, exists: () => false })
    await controller.wake()
    expect(fake.calls.some(call => call[0] === 'start')).toBe(true)
    expect(fake.calls.some(call => call[0] === 'run')).toBe(false)
  })

  it('runs the agent seat and app commands inside the container', async () => {
    const fake = fakeDocker('running')
    const controller = createContainerController(settings, { fence: async () => {}, docker: fake.docker, exists: () => false })
    await controller.wake()
    await controller.ensureAgentSeat()
    expect(fake.calls.at(-1)).toEqual(['exec', '-u', 'root', 'caboose-owner', '/usr/local/bin/caboose-session', 'start-agent'])
    expect(await controller.apps()).toEqual([])
    expect(fake.calls.at(-1)?.slice(0, 4)).toEqual(['exec', '-u', 'caboose', 'caboose-owner'])
  })
})

describe('GPU selection', () => {
  it('detects the GPU a container can use on each kind of host', () => {
    expect(detectGpu(path => path === '/dev/dxg')).toBe('wsl')
    expect(detectGpu(path => path === '/dev/nvidiactl')).toBe('nvidia')
    expect(detectGpu(path => path === '/dev/dri/renderD128')).toBe('dri')
    expect(detectGpu(() => false)).toBe('none')
  })

  it('hands each kind to the container its own way', () => {
    expect(gpuArgs('nvidia')).toEqual(expect.arrayContaining(['--gpus', 'all', 'CABOOSE_GPU=nvidia']))
    expect(gpuArgs('dri', () => false)).toEqual(['--device', '/dev/dri', '-e', 'CABOOSE_GPU=dri'])
    expect(gpuArgs('dri', path => path === '/dev/udmabuf')).toEqual(['--device', '/dev/dri', '--device', '/dev/udmabuf', '-e', 'CABOOSE_GPU=dri'])
    expect(gpuArgs('nvidia', path => path === '/dev/udmabuf')).toEqual(expect.arrayContaining(['--device', '/dev/udmabuf']))
    expect(gpuArgs('wsl', () => true)).not.toContain('/dev/udmabuf')
    expect(gpuArgs('none')).toEqual(['-e', 'CABOOSE_GPU=none'])
  })

  it('uses a configured GPU over detection', async () => {
    const fake = fakeDocker('missing')
    const controller = createContainerController({ ...settings, gpu: 'none' }, { fence: async () => {}, docker: fake.docker, exists: () => true })
    await controller.wake()
    expect(fake.calls.find(call => call[0] === 'run')).toEqual(expect.arrayContaining(['CABOOSE_GPU=none']))
  })
})

describe('container settings and restart', () => {
  it('sizes a new computer from the settings and restarts cold into the new size', async () => {
    const fake = fakeDocker('missing')
    let desired = { name: 'Studio', memoryMb: 8192, vcpus: 6, idleMs: 60_000, defaultAgent: null }
    const controller = createContainerController(settings, { fence: async () => {}, docker: fake.docker, exists: () => false, settings: () => desired })
    const first = await controller.wake()
    expect(first.computer).toMatchObject({ name: 'Studio', memoryMb: 8192, vcpus: 6 })
    expect(controller.activeResources()).toEqual({ memoryMb: 8192, vcpus: 6 })
    desired = { ...desired, memoryMb: 12288 }
    const second = await controller.restart!()
    expect(fake.calls.some(call => call[0] === 'rm')).toBe(true)
    expect(second.computer.memoryMb).toBe(12288)
    expect(second.display.token).not.toBe(first.display.token)
  })

  it('reads the size of a computer that existed before the host started', async () => {
    const fake = fakeDocker('paused')
    const controller = createContainerController(settings, { fence: async () => {}, docker: fake.docker, exists: () => false })
    await controller.wake()
    expect(controller.activeResources()).toEqual({ memoryMb: 4096, vcpus: 2 })
  })
})

describe('container network fence', () => {
  it('puts the computer on its own fenced network with public DNS before it starts', async () => {
    const fake = fakeDocker('missing')
    const fenced: string[] = []
    const controller = createContainerController(settings, { docker: fake.docker, exists: () => false, fence: async device => { fenced.push(device) } })
    await controller.wake()
    expect(fenced).toEqual(['caboose-br0'])
    const network = fake.calls.findIndex(call => call[0] === 'network')
    const run = fake.calls.findIndex(call => call[0] === 'run')
    expect(network).toBeGreaterThanOrEqual(0)
    expect(network).toBeLessThan(run)
    expect(fake.calls[run]).toEqual(expect.arrayContaining(['--network', 'caboose', '--dns', '1.1.1.1']))
  })
})
