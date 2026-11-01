import { EventEmitter } from 'node:events'
import { PassThrough } from 'node:stream'
import type { ChildProcessWithoutNullStreams } from 'node:child_process'
import { describe, expect, it } from 'vitest'
import { HostPads, allowsPads, inputDeviceArgs, linkArgs, makeNodeArgs, parseAdded, parseRemove, sidecarArgs } from './host-pads.js'

class FakeChild extends EventEmitter {
  stdin = new PassThrough()
  stdout = new PassThrough()
  stderr = new PassThrough()
  written: string[] = []
  killed = false
  constructor(readonly args: string[]) {
    super()
    this.stdin.on('data', (chunk: Buffer) => this.written.push(...chunk.toString().split('\n').filter(Boolean)))
  }
  kill() { this.killed = true; this.emit('close', null); return true }
}

const tick = () => new Promise(resolve => setTimeout(resolve, 5))

function rig(options: { mknodFails?: boolean } = {}) {
  const calls: string[][] = []
  const children: FakeChild[] = []
  const pads = new HostPads({
    computer: 'caboose-c-1',
    docker: async args => {
      calls.push(args)
      if (options.mknodFails && args.includes('--privileged')) throw new Error('mknod: Operation not permitted')
      return ''
    },
    image: async () => 'sha256:abc',
    ownerEnv: () => ['DISPLAY=:110', 'XDG_RUNTIME_DIR=/run/user/1000'],
    spawn: args => { const child = new FakeChild(args); children.push(child); return child as unknown as ChildProcessWithoutNullStreams },
    retryMs: 60_000,
    log: () => {},
  })
  return { pads, calls, children, sidecar: () => children[0]!, link: () => children[1]! }
}

describe('host pads', () => {
  it('creates a computer able to open input devices but not to make device nodes', () => {
    expect(inputDeviceArgs()).toEqual(['--device-cgroup-rule', 'c 13:* rwm', '--cap-drop', 'MKNOD'])
    expect(allowsPads('["c 13:* rwm"]')).toBe(true)
    expect(allowsPads('null')).toBe(false)
    expect(allowsPads('running')).toBe(false)
  })

  it('gives only the sidecar uinput, and nothing else', () => {
    const args = sidecarArgs('caboose-c-1', 'sha256:abc')
    expect(args).toEqual(expect.arrayContaining(['--device', '/dev/uinput', '--cap-drop', 'ALL', '--network', 'none', '--read-only', '--name', 'caboose-c-1-pads']))
    expect(args.slice(-2)).toEqual(['sha256:abc', '--host-pads'])
    expect(linkArgs('caboose-c-1', ['XDG_RUNTIME_DIR=/run/user/1000'])).toEqual(['exec', '-i', '-u', 'caboose', 'caboose-c-1', '/usr/bin/env', 'XDG_RUNTIME_DIR=/run/user/1000', '/usr/local/bin/caboose-display', '--pad-link'])
    expect(makeNodeArgs('caboose-c-1', '/dev/input/event7', 13, 71).slice(0, 4)).toEqual(['exec', '--privileged', '-u', 'root'])
  })

  it('accepts only input devices as the sidecar’s nodes', () => {
    expect(parseAdded('{"added":1,"node":"/dev/input/event7","dev":"13:71"}')).toEqual({ id: 1, node: '/dev/input/event7', major: 13, minor: 71 })
    expect(parseAdded('{"added":1,"node":"/dev/uinput","dev":"10:223"}')).toBeNull()
    expect(parseAdded('{"added":1,"node":"/dev/input/event7","dev":"10:223"}')).toBeNull()
    expect(parseAdded('{"added":1,"node":"/dev/input/event7; rm -rf /","dev":"13:71"}')).toBeNull()
    expect(parseAdded('{"added":0,"node":"/dev/input/event7","dev":"13:71"}')).toBeNull()
    expect(parseRemove('{"remove":3}')).toBe(3)
    expect(parseRemove('{"remove":"3"}')).toBeNull()
    expect(parseRemove('{"state":3}')).toBeNull()
  })

  it('makes a pad’s node in the computer before the hub hears of it, and removes it before the pad', async () => {
    const { pads, calls, sidecar, link } = rig()
    pads.start()
    await tick()
    expect(calls[0]).toEqual(['exec', '-u', 'root', 'caboose-c-1', '/bin/sh', '-c', 'mkdir -p /dev/input; rm -f /dev/input/event*'])
    expect(sidecar().args.slice(-1)).toEqual(['--host-pads'])
    expect(link().args.slice(-1)).toEqual(['--pad-link'])

    link().stdout.write('{"add":1,"name":"iPhone Controller","rumble":true}\n')
    await tick()
    expect(sidecar().written).toEqual(['{"add":1,"name":"iPhone Controller","rumble":true}'])

    sidecar().stdout.write('{"added":1,"node":"/dev/input/event7","dev":"13:71"}\n')
    await tick()
    expect(calls.at(-1)).toEqual(['exec', '--privileged', '-u', 'root', 'caboose-c-1', '/bin/sh', '-c', expect.stringContaining('mknod -m 0600'), 'sh', '/dev/input/event7', '13', '71'])
    expect(link().written).toEqual(['{"added":1,"node":"/dev/input/event7","dev":"13:71"}'])

    link().stdout.write('{"state":1,"buttons":1,"axes":[0,0,0,0,0,0]}\n')
    sidecar().stdout.write('{"rumble":1,"strong":1,"weak":0,"ms":100}\n')
    await tick()
    expect(sidecar().written.at(-1)).toBe('{"state":1,"buttons":1,"axes":[0,0,0,0,0,0]}')
    expect(link().written.at(-1)).toBe('{"rumble":1,"strong":1,"weak":0,"ms":100}')

    const before = calls.length
    link().stdout.write('{"remove":1}\n')
    await tick()
    expect(calls[before]).toEqual(['exec', '-u', 'root', 'caboose-c-1', '/bin/rm', '-f', '/dev/input/event7'])
    expect(sidecar().written.at(-1)).toBe('{"remove":1}')
    await pads.stop()
  })

  it('tells the hub when the computer cannot be given the node, and takes the pad down', async () => {
    const { pads, sidecar, link } = rig({ mknodFails: true })
    pads.start()
    await tick()
    sidecar().stdout.write('{"added":2,"node":"/dev/input/event8","dev":"13:72"}\n')
    await tick()
    expect(sidecar().written).toEqual(['{"remove":2}'])
    expect(JSON.parse(link().written[0]!)).toMatchObject({ failed: 2, error: expect.stringContaining('/dev/input/event8') })
    await pads.stop()
  })

  it('clears the computer’s nodes before the pads go when stopped', async () => {
    const { pads, calls, sidecar } = rig()
    pads.start()
    await tick()
    sidecar().stdout.write('{"added":1,"node":"/dev/input/event7","dev":"13:71"}\n')
    await tick()
    const before = calls.length
    const stopping = pads.stop()
    expect(sidecar().killed).toBe(false)
    await stopping
    expect(calls[before]).toEqual(['exec', '-u', 'root', 'caboose-c-1', '/bin/sh', '-c', 'mkdir -p /dev/input; rm -f /dev/input/event*'])
    expect(sidecar().killed).toBe(true)
  })
})
