import { describe, expect, it } from 'vitest'
import { config } from './config.js'
import { containerPlacement, createContainerController, detectGpu, gpuArgs, phoneDeviceArgs, withContainerPorts, type Docker } from './container-driver.js'
import { DISPLAY_ENV } from './display.test.js'

/** `published` are the container ports Docker reports as mapped; the bridge address is 172.18.0.2. */
function fakeDocker(initial: 'missing' | 'running' | 'paused' | 'exited', published = ['14700', '14701']) {
  let status = initial
  const calls: string[][] = []
  const docker: Docker = async args => {
    calls.push(args)
    switch (args[0]) {
      case 'inspect':
        if (status === 'missing') throw new Error('No such object')
        if (args.includes('{{json .HostConfig}}')) return '{"Memory":4294967296,"NanoCpus":2000000000}'
        if (args.some(arg => arg.includes('.IPAddress'))) return '172.18.0.2\n'
        return `${status}\n`
      case 'run': status = 'running'; return 'id\n'
      case 'start': case 'unpause': status = 'running'; return ''
      case 'pause': status = 'paused'; return ''
      case 'stop': status = 'exited'; return ''
      case 'rm': status = 'missing'; return ''
      case 'network': return ''
      case 'port': {
        const port = args[2]!.split('/')[0]!
        const host = { '14700': args[1] === 'caboose-owner' ? '14700' : '20032', '14701': args[1] === 'caboose-owner' ? '14701' : '20033' }[port]
        return published.includes(port) ? `127.0.0.1:${host}\n` : ''
      }
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
  it('starts the owner display only when a headless wake is promoted', async () => {
    const fake = fakeDocker('missing')
    const controller = createContainerController(settings, { fence: async () => {}, docker: fake.docker, exists: () => false })
    const first = await controller.wake('headless')
    expect(fake.calls.some(call => call.includes('/usr/local/bin/caboose-session') && call.includes('start'))).toBe(false)
    const promoted = await controller.promote!()
    expect(promoted.display.token).toBe(first.display.token)
    expect(fake.calls.some(call => call.includes('/usr/local/bin/caboose-session') && call.includes('start'))).toBe(true)
  })
  it('creates the computer with the GPU, its home and loopback-only displays, then starts the session', async () => {
    const fake = fakeDocker('missing')
    const controller = createContainerController(settings, { fence: async () => {}, docker: fake.docker, exists: path => path === '/dev/dxg' })
    const session = await controller.wake()
    expect(session.display.token).toMatch(/^[0-9a-f]{64}$/)
    const run = fake.calls.find(call => call[0] === 'run')!
    expect(run).toEqual(expect.arrayContaining(['--device', '/dev/dxg', 'CABOOSE_GPU=wsl', '-v', '/srv/caboose/home:/home/caboose', '--memory', '6144m', '--cpus', '4',
      '-p', '127.0.0.1:14700:14700', '-p', '127.0.0.1:14701:14701', '-p', '127.0.0.1:14600:14600', '-p', '127.0.0.1:14601:14601', '--security-opt', 'seccomp=unconfined', 'caboose-computer:gpu']))
    expect(run.at(-1)).toBe('caboose-computer:gpu')
    const execs = fake.calls.filter(call => call[0] === 'exec').map(call => call.slice(4).join(' '))
    expect(execs[0]).toContain('/run/caboose/display-token')
    expect(execs).toEqual(expect.arrayContaining(['/usr/local/bin/caboose-session start', '/usr/local/bin/caboose-session ready']))
    expect(controller.guest()).toBeDefined()
    expect(controller.terminalService?.()).toEqual({ url: 'http://127.0.0.1:14701', token: session.display.token })
  })

  it('reaches the terminal on the bridge address of a container created without its port', async () => {
    const fake = fakeDocker('paused', ['14700'])
    const controller = createContainerController(settings, { fence: async () => {}, docker: fake.docker, exists: () => false })
    await controller.wake()
    expect(controller.terminalService?.().url).toBe('http://172.18.0.2:14701')
    expect(controller.componentsWarning?.()).toBeUndefined()
  })

  it('launches apps with the owner display\'s launch environment, and starts the agent seat on demand', async () => {
    const fake = fakeDocker('missing')
    const controller = createContainerController(settings, { fence: async () => {}, docker: fake.docker, exists: () => false })
    const session = await controller.wake()
    expect(session.display.protocol).toBe('caboose-display')
    expect(controller.displayUrl).toBe('ws://127.0.0.1:14600/')
    expect(fake.calls.find(call => call[0] === 'run')).toEqual(expect.arrayContaining(['-p', '127.0.0.1:14600:14600']))
    const execs = fake.calls.filter(call => call[0] === 'exec').map(call => call.slice(4).join(' '))
    expect(execs).not.toContain('/usr/local/bin/caboose-session start-agent')
    await controller.apps()
    expect(fake.calls.at(-1)).toEqual(expect.arrayContaining(['WAYLAND_DISPLAY=wayland-caboose-0', 'DISPLAY=:110',
      'XAUTHORITY=/run/user/1000/caboose-xauth', 'QT_QPA_PLATFORM=wayland;xcb']))
    expect(controller.agentDisplayUrl).toBe('ws://127.0.0.1:14601/')
    await controller.ensureAgentSeat()
    expect(fake.calls.at(-1)).toEqual(expect.arrayContaining(['/usr/local/libexec/caboose-agent-seat']))
  })

  it('parks by freezing and resumes with the same display token', async () => {
    const fake = fakeDocker('missing')
    const controller = createContainerController(settings, { fence: async () => {}, docker: fake.docker, exists: () => false })
    const first = await controller.wake()
    await controller.park()
    expect(fake.calls.at(-1)).toEqual(['pause', 'caboose-owner'])
    expect(controller.guest()).toBeUndefined()
    await controller.wake('headless')
    expect(controller.guest()?.ownerEnv).toEqual([])
    await controller.park()
    const second = await controller.wake()
    expect(fake.calls.some(call => call[0] === 'unpause')).toBe(true)
    expect(second.display.token).toBe(first.display.token)
    expect(fake.calls.filter(call => call[0] === 'run')).toHaveLength(1)
  })

  it('reports a missing Files port mapping on an existing container', async () => {
    const fake = fakeDocker('running')
    const docker: Docker = async (args, timeout) => args[0] === 'port' ? '' : fake.docker(args, timeout)
    const controller = createContainerController(settings, { fence: async () => {}, docker, exists: () => false })
    await controller.wake()
    expect(controller.componentsWarning?.()).toBe('Recreate the container to enable Files.')
    expect(fake.calls.some(call => call[0] === 'rm')).toBe(false)
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
    expect(fake.calls.at(-1)).toEqual(['exec', '-u', 'root', 'caboose-owner', '/usr/local/libexec/caboose-agent-seat'])
    expect(await controller.apps()).toEqual([])
    expect(fake.calls.at(-1)?.slice(0, 4)).toEqual(['exec', '-u', 'caboose', 'caboose-owner'])
    await controller.launch('gimp.desktop', 'Pictures/a.png')
    expect(fake.calls.at(-1)?.slice(-3)).toEqual(['launch', 'gimp.desktop', 'Pictures/a.png'])
    await controller.launch('firefox.desktop', undefined, 'new-private-window')
    expect(fake.calls.at(-1)?.slice(-3)).toEqual(['action', 'firefox.desktop', 'new-private-window'])
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

  it('hands the container uinput and the host input devices when the host has uinput', () => {
    expect(phoneDeviceArgs(path => path === '/dev/uinput')).toEqual([
      '--device', '/dev/uinput', '-v', '/dev/input:/dev/input', '--device-cgroup-rule', 'c 13:* rmw',
    ])
    expect(phoneDeviceArgs(() => false)).toEqual([])
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
    expect(fake.calls.some(call => call[0] === 'rm')).toBe(false)
    expect(fake.calls).toContainEqual(['update', '--memory', '12288m', '--memory-swap', '24576m', '--cpus', '6', 'caboose-owner'])
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
  it('uses Docker-assigned loopback ports for new slots and rediscovers them after park', async () => {
    const fake = fakeDocker('missing')
    const docker: Docker = async (args, timeout) => {
      if (args[0] === 'ps') return ''
      if (args[0] === 'port') return `127.0.0.1:${({ '14600/tcp': 21000, '14601/tcp': 21001, '14700/tcp': 21002, '14701/tcp': 21003 } as Record<string, number>)[args[2]!]}\n`
      return fake.docker(args, timeout)
    }
    const controller = createContainerController(settings, { identity: { id: 'c-0123456789', slot: 64 }, docker, exists: () => false, fence: async () => {} })
    await controller.wake()
    expect(fake.calls.find(call => call[0] === 'run')).toEqual(expect.arrayContaining(['127.0.0.1:21000:14600', '127.0.0.1:21002:14700']))
    expect(controller.displayUrl).toBe('ws://127.0.0.1:21000/')
    expect(controller.fileService?.().url).toBe('http://127.0.0.1:21002')
    await controller.park()
    await controller.wake()
    expect(controller.terminalService?.().url).toBe('http://127.0.0.1:21003')
  })

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

  it("gives every other computer its own container, home, network and ports, and keeps the owner's", async () => {
    expect(containerPlacement(settings, { id: 'owner', slot: 0 })).toEqual({
      name: 'caboose-owner', home: '/srv/caboose/home', network: 'caboose', bridge: 'caboose-br0', ports: { display: 14600, agent: 14601, files: 14700, terminal: 14701 },
    })
    expect(containerPlacement(settings, { id: 'c-0123456789', slot: 3 })).toEqual({
      name: 'caboose-c-0123456789', home: '/srv/caboose/home-c-0123456789', network: 'caboose-3', bridge: 'caboose-br3', ports: { display: 20030, agent: 20031, files: 20032, terminal: 20033 },
    })
    const fake = fakeDocker('missing')
    const fenced: string[] = []
    const controller = createContainerController({ ...settings, containerHome: 'caboose-home' }, { identity: { id: 'c-0123456789', slot: 3 }, fence: async device => { fenced.push(device) }, unfence: async device => { fenced.push(`-${device}`) }, docker: fake.docker, exists: () => false })
    await controller.wake()
    const run = fake.calls.find(call => call[0] === 'run')!
    expect(run).toEqual(expect.arrayContaining(['--name', 'caboose-c-0123456789', '--network', 'caboose-3', '-v', 'caboose-home-c-0123456789:/home/caboose',
      '-p', '127.0.0.1:20030:14600', '-p', '127.0.0.1:20031:14601', '-p', '127.0.0.1:20032:14700', '-p', '127.0.0.1:20033:14701']))
    expect(controller.displayUrl).toBe('ws://127.0.0.1:20030/')
    expect(controller.fileService?.().url).toBe('http://127.0.0.1:20032')
    expect(controller.terminalService?.().url).toBe('http://127.0.0.1:20033')
    await controller.destroy!()
    expect(fake.calls.filter(call => ['rm', 'volume', 'network'].includes(call[0]!)).map(call => call.join(' '))).toEqual(expect.arrayContaining([
      'rm -f caboose-c-0123456789', 'volume rm -f caboose-home-c-0123456789', 'network rm caboose-3',
    ]))
    expect(fenced).toEqual(['caboose-br3', '-caboose-br3'])
    expect(controller.guest()).toBeUndefined()
  })
})


it('avoids ports recorded by stopped containers and serializes new allocations', async () => {
  let published = false
  const docker: Docker = async args => {
    if (args[0] === 'ps') return 'stopped\n'
    if (args[0] === 'inspect') return `${JSON.stringify({ '14600/tcp': [{ HostIp: '127.0.0.1', HostPort: '21000' }], ...(published ? { '14700/tcp': [{ HostIp: '127.0.0.1', HostPort: '21004' }] } : {}) })}\t${JSON.stringify({ '14701/tcp': [{ HostPort: '21012' }] })}`
    return ''
  }
  const a = withContainerPorts(docker, async ports => { published = true; return ports })
  const b = withContainerPorts(docker, async ports => ports)
  expect((await a).display).toBe(21004)
  expect((await b).display).toBe(21008)
})

it('skips an occupied host listener before selecting a port block', async () => {
  const { createServer } = await import('node:net')
  const { portsAvailable } = await import('./container-driver.js')
  const server = createServer()
  await new Promise<void>(resolve => server.listen(0, '127.0.0.1', resolve))
  try {
    const address = server.address()
    if (!address || typeof address === 'string') throw new Error('No test port')
    const docker: Docker = async () => ''
    const picked = await withContainerPorts(docker, async ports => ports, ports => ports[0] === 21000 ? portsAvailable([address.port]) : Promise.resolve(true))
    expect(picked.display).toBe(21004)
  } finally { await new Promise<void>(resolve => server.close(() => resolve())) }
})

it('removes only its failed bind attempt and retries with new ports', async () => {
  const fake = fakeDocker('missing')
  const calls: string[][] = []
  let attempt = '', runs = 0
  const id = 'a'.repeat(64)
  const docker: Docker = async (args, timeout) => {
    calls.push(args)
    if (args[0] === 'ps') return ''
    if (args[0] === 'run') {
      runs++
      if (runs === 1) {
        attempt = args.find(arg => arg.startsWith('caboose.port-attempt='))!.split('=')[1]!
        throw new Error('port is already allocated')
      }
    }
    if (args[0] === 'inspect' && args.includes('{{json .}}')) return JSON.stringify({ Id: id, State: { Status: 'created' }, Config: { Labels: { 'caboose.port-attempt': attempt } } })
    if (args[0] === 'rm' && args[1] === id) return ''
    if (args[0] === 'port') return `127.0.0.1:${({ '14600/tcp': 21004, '14601/tcp': 21005, '14700/tcp': 21006, '14701/tcp': 21007 } as Record<string, number>)[args[2]!]}\n`
    return fake.docker(args, timeout)
  }
  const controller = createContainerController(settings, { identity: { id: 'c-0123456789', slot: 64 }, docker, exists: () => false, fence: async () => {} })
  await controller.wake()
  expect(runs).toBe(2)
  expect(calls.filter(call => call[0] === 'rm')).toEqual([['rm', id]])
  expect(calls.filter(call => call[0] === 'run')[1]).toContain('127.0.0.1:21004:14600')
  expect(calls.some(call => call[0] === 'volume' || (call[0] === 'network' && call[1] === 'rm'))).toBe(false)
})

it('never removes an existing container when a bind failure cannot prove ownership', async () => {
  const fake = fakeDocker('missing')
  const calls: string[][] = []
  const docker: Docker = async (args, timeout) => {
    calls.push(args)
    if (args[0] === 'ps') return ''
    if (args[0] === 'run') throw new Error('port is already allocated')
    if (args[0] === 'inspect' && args.includes('{{json .}}')) return JSON.stringify({ Id: 'b'.repeat(64), State: { Status: 'created' }, Config: { Labels: { 'caboose.port-attempt': 'someone-else' } } })
    return fake.docker(args, timeout)
  }
  const controller = createContainerController(settings, { identity: { id: 'c-0123456789', slot: 64 }, docker, exists: () => false, fence: async () => {} })
  await expect(controller.wake()).rejects.toThrow('port is already allocated')
  expect(calls.some(call => call[0] === 'rm' || call[0] === 'volume')).toBe(false)
})
