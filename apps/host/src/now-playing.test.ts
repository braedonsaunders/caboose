import { describe, expect, it } from 'vitest'
import type { AgentGuest } from './agents.js'
import { NowPlaying, NowPlayingInputError, READ_SCRIPT, WRITE_SCRIPT, parseNowPlayingCommand, parseNowPlayingState, type NowPlayingEvent } from './now-playing.js'

const track = {
  id: 'spotify.4f1c2a-7', player: 'Spotify', title: 'Teardrop', artist: 'Massive Attack', album: 'Mezzanine',
  artwork: 'https://i.scdn.co/image/ab67616d0000b273', position: 30, duration: 330, paused: false, rate: 1,
  canPlay: true, canPause: true, canNext: true, canPrevious: true, canSeek: true, updatedAt: 1_793_161_915_000,
}

/** A guest whose state file and clock the test sets; it records every command it runs. */
function fakeGuest() {
  let file = ''
  let clock = track.updatedAt
  const calls: string[][] = []
  const guest: AgentGuest = {
    async run(command, args) {
      calls.push([command, ...args])
      if (args.includes(READ_SCRIPT)) return `${file}\n__CABOOSE_NOW__${clock}`
      return ''
    },
  }
  return {
    guest,
    writes: () => calls.filter(call => call.includes(WRITE_SCRIPT)).map(call => JSON.parse(call.at(-1)!)),
    set: (state: object | string) => { file = typeof state === 'string' ? state : JSON.stringify(state) },
    tick: (ms: number) => { clock += ms },
  }
}

describe('parseNowPlayingState', () => {
  it('accepts the guest contract', () => {
    expect(parseNowPlayingState(track)).toEqual(track)
    const live = { ...track, duration: null, artwork: null, paused: true, canSeek: false }
    expect(parseNowPlayingState(live)).toEqual(live)
  })

  it('keeps only https artwork', () => {
    for (const artwork of ['file:///home/caboose/.cache/cover.png', 'http://example.com/a.png', 'https://a b', 'x'.repeat(5000), 7]) {
      expect(parseNowPlayingState({ ...track, artwork })?.artwork, String(artwork)).toBeNull()
    }
  })

  it('rejects anything malformed', () => {
    for (const bad of [
      null, [], {}, { ...track, id: 'a/b' }, { ...track, id: '' }, { ...track, player: 'p'.repeat(101) }, { ...track, title: 't'.repeat(301) },
      { ...track, artist: 3 }, { ...track, position: -1 }, { ...track, duration: 'long' }, { ...track, rate: 17 }, { ...track, rate: -1 },
      { ...track, paused: 'no' }, { ...track, canSeek: undefined }, { ...track, updatedAt: 1.5 },
    ]) expect(parseNowPlayingState(bad), JSON.stringify(bad)).toBeNull()
  })
})

describe('parseNowPlayingCommand', () => {
  it('accepts every action, and seek with a position', () => {
    for (const action of ['play', 'pause', 'toggle', 'next', 'previous']) expect(parseNowPlayingCommand(track.id, { action })).toEqual({ id: track.id, action })
    expect(parseNowPlayingCommand(track.id, { action: 'seek', position: 12.5 })).toEqual({ id: track.id, action: 'seek', position: 12.5 })
  })

  it('rejects everything else', () => {
    for (const [id, body] of [
      ['a%2Fb', { action: 'play' }], [track.id, {}], [track.id, { action: 'stop' }], [track.id, { action: 'seek' }],
      [track.id, { action: 'seek', position: -1 }], [track.id, { action: 'seek', position: 1e8 }], [track.id, { action: 'play', position: 3 }],
      [track.id, { action: 'play', extra: true }],
    ] as const) expect(() => parseNowPlayingCommand(id, body as Record<string, unknown>), `${id} ${JSON.stringify(body)}`).toThrow(NowPlayingInputError)
  })
})

describe('NowPlaying', () => {
  it('emits changed on each change and stopped when the player or track changes', async () => {
    const fake = fakeGuest()
    const events: NowPlayingEvent[] = []
    const nowPlaying = new NowPlaying(() => fake.guest, event => events.push(event), 60_000, () => 5_000)
    fake.set(track)
    await nowPlaying.poll()
    expect(events).toEqual([{ type: 'now-playing.changed', nowPlaying: { ...track, updatedAt: 5_000 } }])
    await nowPlaying.poll()
    expect(events).toHaveLength(1)
    fake.set({ ...track, id: 'spotify.4f1c2a-8', title: 'Angel', position: 0 })
    await nowPlaying.poll()
    expect(events.slice(1).map(event => event.type)).toEqual(['now-playing.stopped', 'now-playing.changed'])
    fake.set('')
    await nowPlaying.poll()
    expect(events.at(-1)).toEqual({ type: 'now-playing.stopped', id: 'spotify.4f1c2a-8' })
    expect(nowPlaying.current()).toBeNull()
  })

  it('extrapolates the position with the playback rate on the guest clock, capped at the duration', async () => {
    const fake = fakeGuest()
    let now = 10_000
    const nowPlaying = new NowPlaying(() => fake.guest, () => {}, 60_000, () => now)
    fake.set({ ...track, rate: 2 })
    fake.tick(1000) // sampled a second ago by the guest's clock
    await nowPlaying.poll()
    expect(nowPlaying.current()?.position).toBe(32)
    now += 500
    expect(nowPlaying.current()?.position).toBe(33)
    now += 1_000_000
    expect(nowPlaying.current()?.position).toBe(330)
    fake.set({ ...track, paused: true })
    await nowPlaying.poll()
    now += 5000
    expect(nowPlaying.current()?.position).toBe(30)
  })

  it('reads on demand only while running, and forgets the track when the computer stops', async () => {
    const fake = fakeGuest()
    const events: NowPlayingEvent[] = []
    const nowPlaying = new NowPlaying(() => fake.guest, event => events.push(event), 60_000, () => 1)
    fake.set(track)
    expect(await nowPlaying.read(false)).toBeNull()
    expect((await nowPlaying.read(true))?.id).toBe(track.id)
    expect(nowPlaying.watched()).toBeNull()
    nowPlaying.computerStopped()
    expect(events.at(-1)).toEqual({ type: 'now-playing.stopped', id: track.id })
  })

  it('writes commands with increasing, millisecond-based sequence numbers', async () => {
    const fake = fakeGuest()
    const nowPlaying = new NowPlaying(() => fake.guest, () => {}, 60_000, () => 1_000)
    await nowPlaying.send({ id: track.id, action: 'pause' })
    await nowPlaying.send({ id: track.id, action: 'seek', position: 90 })
    expect(fake.writes()).toEqual([{ seq: 1_000, id: track.id, action: 'pause' }, { seq: 1_001, id: track.id, action: 'seek', position: 90 }])
  })
})
