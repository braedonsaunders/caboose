import { once } from 'node:events'
import type { AddressInfo } from 'node:net'
import { WebSocket, WebSocketServer } from 'ws'
import { afterEach, describe, expect, it, vi } from 'vitest'
import type { AgentGuest } from './agents.js'
import { MediaHandoff, MediaInputError, parseMediaCommand, parseMediaState, READ_SCRIPT, WRITE_SCRIPT, type MediaEvent } from './media.js'
import { createCabooseServer, type Controller } from './server.js'
import { SettingsStore, settingsLimits } from './settings.js'

const youtube = {
  id: '1944008823.0.0gqc72sh-1', page: 'https://www.youtube.com/watch?v=jNQXAC9IVRw', title: 'Me at the zoo',
  kind: 'youtube', videoId: 'jNQXAC9IVRw', position: 10, duration: 19, paused: false, updatedAt: 1_793_161_915_000,
}

/** A guest whose state file and clock the test sets; it records every command it runs. */
function fakeGuest() {
  let file = ''
  let clock = youtube.updatedAt
  const calls: string[][] = []
  const guest: AgentGuest = {
    async run(command, args) {
      calls.push([command, ...args])
      if (args.includes(READ_SCRIPT)) return `${file}\n__CABOOSE_NOW__${clock}`
      return ''
    },
  }
  return {
    guest, calls,
    reads: () => calls.filter(call => call.includes(READ_SCRIPT)).length,
    writes: () => calls.filter(call => call.includes(WRITE_SCRIPT)).map(call => JSON.parse(call.at(-1)!)),
    set: (state: object | string) => { file = typeof state === 'string' ? state : JSON.stringify(state) },
    tick: (ms: number) => { clock += ms },
  }
}

describe('parseMediaState', () => {
  it('accepts the guest contract', () => {
    expect(parseMediaState(youtube)).toEqual(youtube)
    const hls = { id: '4.2.ab-1', page: 'https://example.com/live', title: 'Live', src: 'https://cdn.example.com/a.m3u8', kind: 'hls', position: 0, duration: null, paused: true, updatedAt: 1 }
    expect(parseMediaState(hls)).toEqual(hls)
    expect(parseMediaState({ ...hls, title: undefined })?.title).toBe('')
  })

  it('rejects anything malformed', () => {
    for (const bad of [
      null, [], {}, { ...youtube, id: 'a/b' }, { ...youtube, id: 'x'.repeat(65) }, { ...youtube, videoId: 'short' },
      { ...youtube, kind: 'dash' }, { ...youtube, page: 'javascript:alert(1)' }, { ...youtube, position: -1 },
      { ...youtube, position: Number.NaN }, { ...youtube, duration: 'long' }, { ...youtube, paused: 'no' },
      { ...youtube, updatedAt: 1.5 }, { ...youtube, kind: 'video', videoId: undefined, src: 'blob:https://example.com/1' },
      { ...youtube, kind: 'video', videoId: undefined }, { ...youtube, src: 'data:video/mp4,' },
    ]) expect(parseMediaState(bad), JSON.stringify(bad)).toBeNull()
  })
})

describe('parseMediaCommand', () => {
  it('accepts pause, play, and play at a position', () => {
    expect(parseMediaCommand('7.0.k3-1', { action: 'pause' })).toEqual({ id: '7.0.k3-1', action: 'pause' })
    expect(parseMediaCommand('7.0.k3-1', { action: 'play' })).toEqual({ id: '7.0.k3-1', action: 'play' })
    expect(parseMediaCommand('7.0.k3-1', { action: 'play', position: 42.5 })).toEqual({ id: '7.0.k3-1', action: 'play', position: 42.5 })
  })

  it('rejects everything else', () => {
    for (const [id, body] of [
      ['a%2Fb', { action: 'pause' }], ['', { action: 'pause' }], ['x'.repeat(65), { action: 'pause' }],
      ['7.0.k3-1', {}], ['7.0.k3-1', { action: 'stop' }], ['7.0.k3-1', { action: 'pause', position: 3 }],
      ['7.0.k3-1', { action: 'play', position: -1 }], ['7.0.k3-1', { action: 'play', position: '3' }],
      ['7.0.k3-1', { action: 'play', position: 1e8 }], ['7.0.k3-1', { action: 'play', extra: true }],
    ] as const) expect(() => parseMediaCommand(id, body as Record<string, unknown>), `${id} ${JSON.stringify(body)}`).toThrow(MediaInputError)
  })
})

describe('MediaHandoff', () => {
  afterEach(() => { vi.useRealTimers() })

  it('emits playing on each change and stopped when the video goes or changes', async () => {
    const fake = fakeGuest()
    const events: MediaEvent[] = []
    const media = new MediaHandoff(() => fake.guest, event => events.push(event), 60_000, () => 5_000)
    fake.set(youtube)
    await media.poll()
    await media.poll()
    fake.set({ ...youtube, position: 15, updatedAt: youtube.updatedAt + 5000 })
    await media.poll()
    fake.set({ ...youtube, id: '1944008823.0.0gqc72sh-2', videoId: 'dQw4w9WgXcQ', position: 0 })
    await media.poll()
    fake.set('')
    await media.poll()
    fake.set('{"not": "valid"}')
    await media.poll()
    expect(events.map(event => event.type === 'media.playing' ? `playing ${event.media.id}` : `stopped ${event.id}`)).toEqual([
      'playing 1944008823.0.0gqc72sh-1', 'playing 1944008823.0.0gqc72sh-1',
      'stopped 1944008823.0.0gqc72sh-1', 'playing 1944008823.0.0gqc72sh-2', 'stopped 1944008823.0.0gqc72sh-2',
    ])
    expect(events[0]).toEqual({ type: 'media.playing', media: { ...youtube, updatedAt: 5_000 } })
  })

  it('extrapolates a playing position on the host clock, whatever the guest clock says', async () => {
    const fake = fakeGuest()
    let now = 1_000_000
    const media = new MediaHandoff(() => fake.guest, () => {}, 60_000, () => now)
    fake.set(youtube)
    fake.tick(2_000) // sampled 2 s before the read, by the guest's own (skewed) clock
    await media.poll()
    expect(media.current()).toMatchObject({ position: 12, updatedAt: 1_000_000 })
    now += 3_500
    expect(media.current()).toMatchObject({ position: 15.5, updatedAt: 1_003_500 })
    now += 60_000
    expect(media.current()?.position).toBe(19)
    fake.set({ ...youtube, paused: true })
    await media.poll()
    now += 10_000
    expect(media.current()?.position).toBe(10)
    fake.set({ ...youtube, duration: null, position: 100 })
    await media.poll()
    now += 60_000
    expect(media.current()?.position).toBe(162)
  })

  it('polls only while active, and announces the state again when polling restarts', async () => {
    vi.useFakeTimers()
    const fake = fakeGuest()
    const events: MediaEvent[] = []
    const media = new MediaHandoff(() => fake.guest, event => events.push(event), 1000)
    fake.set(youtube)
    await vi.advanceTimersByTimeAsync(5_000)
    expect(fake.reads()).toBe(0)
    media.setActive(true)
    media.setActive(true)
    await vi.advanceTimersByTimeAsync(2_500)
    expect(fake.reads()).toBe(3)
    expect(events).toHaveLength(1)
    media.setActive(false)
    await vi.advanceTimersByTimeAsync(5_000)
    expect(fake.reads()).toBe(3)
    expect(media.watched()).toBeNull()
    media.setActive(true)
    await vi.advanceTimersByTimeAsync(0)
    expect(events.map(event => event.type)).toEqual(['media.playing', 'media.playing'])
    expect(media.watched()?.id).toBe(youtube.id)
    media.computerStopped()
    expect(media.active).toBe(false)
    expect(events.at(-1)).toEqual({ type: 'media.stopped', id: youtube.id })
    expect(media.current()).toBeNull()
  })

  it('reads on demand only from a running computer', async () => {
    const fake = fakeGuest()
    const media = new MediaHandoff(() => fake.guest, () => {}, 60_000)
    fake.set(youtube)
    expect(await media.read(false)).toBeNull()
    expect(fake.reads()).toBe(0)
    expect((await media.read(true))?.id).toBe(youtube.id)
    expect(fake.reads()).toBe(1)
    expect(await new MediaHandoff(() => undefined, () => {}).read(true)).toBeNull()
  })

  it('keeps the last state when a read fails', async () => {
    const fake = fakeGuest()
    let broken = false
    const guest: AgentGuest = { run: async (command, args) => { if (broken) throw new Error('guest gone'); return fake.guest.run(command, args) } }
    const events: MediaEvent[] = []
    const media = new MediaHandoff(() => guest, event => events.push(event), 60_000)
    fake.set(youtube)
    await media.poll()
    broken = true
    await expect(media.poll()).resolves.toBeUndefined()
    expect(media.current()?.id).toBe(youtube.id)
    expect(events).toHaveLength(1)
  })

  it('writes commands as caboose with an increasing seq', async () => {
    const fake = fakeGuest()
    const media = new MediaHandoff(() => fake.guest, () => {}, 60_000, () => 1_000)
    await media.send({ id: youtube.id, action: 'pause' })
    await media.send({ id: youtube.id, action: 'play', position: 42.5 })
    expect(fake.writes()).toEqual([
      { seq: 1_000, id: youtube.id, action: 'pause' },
      { seq: 1_001, id: youtube.id, action: 'play', position: 42.5 },
    ])
    expect(fake.calls[0]!.slice(0, 4)).toEqual(['/usr/sbin/runuser', '-u', 'caboose', '--'])
    await expect(new MediaHandoff(() => undefined, () => {}).send({ id: 'a', action: 'pause' })).rejects.toThrow('computer is not running')
  })
})

describe('media routes', () => {
  const close: Array<() => Promise<void>> = []
  afterEach(async () => { for (const f of close.splice(0)) await f() })

  async function fixture() {
    const fake = fakeGuest()
    fake.set(youtube)
    const upstream = new WebSocketServer({ port: 0 })
    await once(upstream, 'listening')
    close.push(() => new Promise(resolve => upstream.close(() => resolve())))
    let running = false
    const controller: Controller = {
      wake: vi.fn(async () => { running = true; return { state: 'running', display: { path: '/v1/display', token: 'display', protocol: 'xpra-ws' as const }, computer: { name: 'Caboose', image: 'Debian', memoryMb: 2048, vcpus: 2 } } }),
      park: vi.fn(async () => { running = false }), activeResources: () => null, hasSavedState: () => false, stats: () => ({}),
      apps: async () => [], launch: async () => {}, ensureAgentSeat: async () => {},
      displayUrl: `ws://127.0.0.1:${(upstream.address() as AddressInfo).port}`, agentDisplayUrl: 'ws://127.0.0.1:1',
      guest: () => running ? fake.guest : undefined,
    }
    const settings = new SettingsStore({ name: 'Caboose', memoryMb: 2048, vcpus: 2, idleMs: 600_000 }, settingsLimits(), { load: async () => undefined, save: async () => {} })
    const app = createCabooseServer({ token: 'owner', settings, controller })
    app.server.listen(0, '127.0.0.1')
    await once(app.server, 'listening')
    close.push(() => app.shutdown())
    const base = `http://127.0.0.1:${(app.server.address() as AddressInfo).port}`
    const request = (path: string, method = 'GET', body?: unknown) => fetch(base + path, {
      method, headers: { authorization: 'Bearer owner', 'content-type': 'application/json' },
      ...(body === undefined ? {} : { body: JSON.stringify(body) }),
    })
    const socket = async (path: string, protocol?: string) => {
      const client = new WebSocket(base.replace('http:', 'ws:') + path, protocol ? [protocol] : [], { headers: { authorization: 'Bearer owner' } })
      const messages: Array<{ type: string; [key: string]: unknown }> = []
      client.on('message', data => { if (path === '/v1/control') messages.push(JSON.parse(String(data))) })
      await once(client, 'open')
      close.unshift(async () => { client.terminate() })
      return { client, messages }
    }
    return { fake, controller, app, base, request, socket }
  }

  it('never wakes a parked computer and validates control requests', async () => {
    const { request, base, controller, fake } = await fixture()
    expect((await fetch(`${base}/v1/media`)).status).toBe(401)
    expect(await (await request('/v1/media')).json()).toEqual({ media: null })
    expect((await request('/v1/media/a.b-1/control', 'POST', { action: 'pause' })).status).toBe(409)
    expect((await request('/v1/media/a%2Fb/control', 'POST', { action: 'pause' })).status).toBe(400)
    expect((await request('/v1/media/a.b-1/control', 'POST', { action: 'stop' })).status).toBe(400)
    expect(controller.wake).not.toHaveBeenCalled()
    expect(fake.calls).toEqual([])
  })

  it('polls only with a display client, emits media events, and relays commands', async () => {
    const { request, socket, fake, app } = await fixture()
    await request('/v1/session', 'POST')
    const control = await socket('/v1/control')
    await new Promise(resolve => setTimeout(resolve, 50))
    expect(fake.reads()).toBe(0)
    expect((await (await request('/v1/media')).json()).media).toMatchObject({ id: youtube.id, kind: 'youtube', videoId: 'jNQXAC9IVRw' })
    expect(fake.reads()).toBe(1)

    const display = await socket('/v1/display', 'binary')
    await vi.waitFor(() => expect(control.messages.some(message => message.type === 'media.playing')).toBe(true))
    expect(control.messages.find(message => message.type === 'media.playing')).toMatchObject({ media: { id: youtube.id, title: 'Me at the zoo' } })
    const second = await socket('/v1/control')
    await vi.waitFor(() => expect(second.messages.map(message => message.type)).toEqual(['computer.state', 'computer.settings', 'media.playing']))

    expect(await (await request(`/v1/media/${youtube.id}/control`, 'POST', { action: 'play', position: 12 })).json()).toEqual({ sent: true })
    expect(fake.writes()).toEqual([expect.objectContaining({ id: youtube.id, action: 'play', position: 12 })])

    fake.set('')
    await vi.waitFor(() => expect(control.messages.at(-1)).toEqual({ type: 'media.stopped', id: youtube.id }), { timeout: 3000 })
    display.client.close()
    await once(display.client, 'close')
    await new Promise(resolve => setTimeout(resolve, 50))
    const reads = fake.reads()
    await new Promise(resolve => setTimeout(resolve, 1300))
    expect(fake.reads()).toBe(reads)
    expect(app.computer.state).toBe('running')
  })
})
