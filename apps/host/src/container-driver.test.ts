import { describe, expect, it } from 'vitest'
import { config } from './config.js'
import { createContainerController, type Docker } from './container-driver.js'

function fakeDocker(initial: 'missing' | 'running' | 'paused' | 'exited') {
  let status = initial
  const calls: string[][] = []
  const docker: Docker = async args => {
    calls.push(args)
    switch (args[0]) {
      case 'inspect':
        if (status === 'missing') throw new Error('No such object')
        return `${status}\n`
      case 'run': status = 'running'; return 'id\n'
      case 'start': case 'unpause': status = 'running'; return ''
      case 'pause': status = 'paused'; return ''
      case 'exec':
        if (args.includes('list')) return '[]'
        return ''
      default: return ''
    }
  }
  return { docker, calls }
}

const settings = config({
  CABOOSE_OWNER_TOKEN: 'x', CABOOSE_RUNTIME: 'container', CABOOSE_MEMORY_MB: '6144', CABOOSE_VCPUS: '4',
  CABOOSE_CONTAINER_IMAGE: 'caboose-computer:gpu', CABOOSE_CONTAINER_HOME: '/srv/caboose/home', CABOOSE_CONTAINER_ARGS: '--security-opt seccomp=unconfined',
})

describe('createContainerController', () => {
  it('creates the computer with the GPU, its home and loopback-only displays, then starts the session', async () => {
    const fake = fakeDocker('missing')
    const controller = createContainerController(settings, { docker: fake.docker, gpuDevice: '/' })
    const session = await controller.wake()
    expect(session.display.token).toMatch(/^[0-9a-f]{64}$/)
    const run = fake.calls.find(call => call[0] === 'run')!
    expect(run).toEqual(expect.arrayContaining(['--device', '/', '-v', '/srv/caboose/home:/home/caboose', '--memory', '6144m', '--cpus', '4',
      '-p', '127.0.0.1:14500:14500', '--security-opt', 'seccomp=unconfined', 'caboose-computer:gpu']))
    expect(run.at(-1)).toBe('caboose-computer:gpu')
    const execs = fake.calls.filter(call => call[0] === 'exec').map(call => call.slice(4).join(' '))
    expect(execs[0]).toContain('/run/caboose/xpra-token')
    expect(execs).toEqual(expect.arrayContaining(['/usr/local/bin/caboose-session start', '/usr/local/bin/caboose-session ready :100']))
    expect(controller.guest()).toBeDefined()
  })

  it('parks by freezing and resumes with the same display token', async () => {
    const fake = fakeDocker('missing')
    const controller = createContainerController(settings, { docker: fake.docker, gpuDevice: '/nonexistent' })
    const first = await controller.wake()
    await controller.park()
    expect(fake.calls.at(-1)).toEqual(['pause', 'caboose-owner'])
    expect(controller.guest()).toBeUndefined()
    const second = await controller.wake()
    expect(fake.calls.some(call => call[0] === 'unpause')).toBe(true)
    expect(second.display.token).toBe(first.display.token)
    expect(fake.calls.filter(call => call[0] === 'run')).toHaveLength(1)
  })

  it('starts a stopped computer instead of recreating it, and leaves out the GPU when the host has none', async () => {
    const fake = fakeDocker('exited')
    const controller = createContainerController(settings, { docker: fake.docker, gpuDevice: '/nonexistent' })
    await controller.wake()
    expect(fake.calls.some(call => call[0] === 'start')).toBe(true)
    expect(fake.calls.some(call => call[0] === 'run')).toBe(false)
  })

  it('runs the agent seat and app commands inside the container', async () => {
    const fake = fakeDocker('running')
    const controller = createContainerController(settings, { docker: fake.docker, gpuDevice: '/nonexistent' })
    await controller.wake()
    await controller.ensureAgentSeat()
    expect(fake.calls.at(-1)).toEqual(['exec', '-u', 'root', 'caboose-owner', '/usr/local/bin/caboose-session', 'start-agent'])
    expect(await controller.apps()).toEqual([])
    expect(fake.calls.at(-1)?.slice(0, 4)).toEqual(['exec', '-u', 'caboose', 'caboose-owner'])
  })
})
