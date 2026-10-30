import { afterEach, describe, expect, it, vi } from 'vitest'
import { AgentNotFoundError, AgentOperationError, type AgentGuest } from './agents.js'
import {
  BridgeInputError, BridgeRateLimitError, BridgeRelay, GEOLOCATION_FILE, GEOLOCATION_WRITE_SCRIPT, LOCATION_EXPIRY_MS, LocationShare,
  OUTSTANDING_MS, geolocationFile, parseAppearance, parseBridgeAnswer, parseBridgeRequest, parseLocation, type BridgeEvent,
} from './bridge.js'

const open = {
  id: '0123456789abcdef0123456789abcdef', type: 'file.open', app: 'org.libreoffice.LibreOffice', title: 'Open',
  acceptLabel: '', multiple: false, directory: false,
  filters: [{ name: 'Documents', patterns: ['*.odt', '*.docx'], mimeTypes: ['application/vnd.oasis.opendocument.text'] }],
  currentFilter: 0, currentName: '', currentFolder: '/home/caboose/Documents', created: 1_793_161_915,
}
const save = { ...open, id: 'fedcba9876543210fedcba9876543210', type: 'file.save', title: 'Save As', currentName: 'Report.odt', currentFilter: null }

/** A guest that answers caboose-bridge commands from the test and records every command. */
function fakeGuest() {
  const calls: string[][] = []
  let drained: unknown = { requests: [], cancels: [] }
  let respond: (answer: unknown) => string = () => '{"answered":true}'
  const guest: AgentGuest = {
    async run(command, args) {
      calls.push([command, ...args])
      const bridge = args.indexOf('/usr/local/bin/caboose-bridge')
      if (bridge >= 0 && args[bridge + 1] === 'drain') {
        const output = typeof drained === 'string' ? drained : JSON.stringify(drained)
        drained = { requests: [], cancels: [] }
        return output
      }
      if (bridge >= 0 && args[bridge + 1] === 'respond') return respond(JSON.parse(args[bridge + 2]!))
      return ''
    },
  }
  return {
    guest, calls,
    drain: (value: unknown) => { drained = value },
    onRespond: (handler: (answer: unknown) => string) => { respond = handler },
    bridgeCalls: (sub: string) => calls.filter(call => call.includes('/usr/local/bin/caboose-bridge') && call.includes(sub)),
  }
}

describe('parseBridgeRequest', () => {
  it('accepts the guest contract', () => {
    expect(parseBridgeRequest(open)).toEqual(open)
    expect(parseBridgeRequest(save)).toEqual(save)
    const folder = { ...open, directory: true, filters: [], currentFilter: null, currentFolder: '' }
    expect(parseBridgeRequest(folder)).toEqual(folder)
    expect(parseBridgeRequest({ ...open, currentFolder: '/home/caboose' })?.currentFolder).toBe('/home/caboose')
  })

  it('rejects anything malformed', () => {
    for (const bad of [
      null, [], {}, { ...open, id: 'ABC' }, { ...open, id: '0123456789abcdef0123456789abcde' }, { ...open, type: 'file.delete' },
      { ...open, app: 'a'.repeat(201) }, { ...open, title: 'line\nbreak' }, { ...open, acceptLabel: 'x'.repeat(65) },
      { ...open, multiple: 'yes' }, { ...save, multiple: true }, { ...save, directory: true },
      { ...open, filters: 'all' }, { ...open, filters: Array(33).fill(open.filters[0]) },
      { ...open, filters: [{ name: 'A', patterns: ['*.a'] }] }, { ...open, filters: [{ name: 'A', patterns: [''], mimeTypes: [] }] },
      { ...open, filters: [{ name: 'A', patterns: [], mimeTypes: ['not a type'] }] }, { ...open, currentFilter: 1 },
      { ...open, currentFilter: -1 }, { ...open, currentName: 'a.txt' }, { ...save, currentName: 'a/b.txt' }, { ...save, currentName: '..' },
      { ...open, currentFolder: '/etc' }, { ...open, currentFolder: '/home/caboose/../root' }, { ...open, currentFolder: '/home/caboose//x' },
      { ...open, currentFolder: '/home/caboosex' }, { ...open, created: -1 }, { ...open, created: 1.5 },
    ]) expect(parseBridgeRequest(bad), JSON.stringify(bad)).toBeNull()
  })
})

describe('parseBridgeAnswer', () => {
  const one = { type: 'file.open' as const, multiple: false, filters: 1 }
  it('accepts ok, cancel and computer', () => {
    expect(parseBridgeAnswer(open.id, { response: 'ok', paths: ['/home/caboose/a.odt'] }, one)).toEqual({ id: open.id, response: 'ok', paths: ['/home/caboose/a.odt'], filter: null })
    expect(parseBridgeAnswer(open.id, { response: 'ok', paths: ['/home/caboose/a', '/home/caboose/b'], filter: 0 }, { ...one, multiple: true }))
      .toEqual({ id: open.id, response: 'ok', paths: ['/home/caboose/a', '/home/caboose/b'], filter: 0 })
    expect(parseBridgeAnswer(open.id, { response: 'cancel' }, one)).toEqual({ id: open.id, response: 'cancel' })
    expect(parseBridgeAnswer(open.id, { response: 'computer' }, one)).toEqual({ id: open.id, response: 'computer' })
  })

  it('rejects everything else', () => {
    for (const [body, request] of [
      [{}, one], [{ response: 'yes' }, one], [{ response: 'cancel', paths: [] }, one], [{ response: 'ok' }, one],
      [{ response: 'ok', paths: [] }, one], [{ response: 'ok', paths: ['/home/caboose/a', '/home/caboose/b'] }, one],
      [{ response: 'ok', paths: ['/home/caboose/a', '/home/caboose/b'] }, { ...one, type: 'file.save' as const, multiple: true }],
      [{ response: 'ok', paths: ['/home/caboose/a', '/home/caboose/a'] }, { ...one, multiple: true }],
      [{ response: 'ok', paths: ['/home/caboose'] }, one], [{ response: 'ok', paths: ['/etc/passwd'] }, one],
      [{ response: 'ok', paths: ['/home/caboose/../x'] }, one], [{ response: 'ok', paths: ['/home/caboose/./x'] }, one],
      [{ response: 'ok', paths: ['/home/caboose/a\u0000'] }, one], [{ response: 'ok', paths: ['/home/caboose/' + 'a'.repeat(5000)] }, one],
      [{ response: 'ok', paths: ['/home/caboose/a'], filter: 1 }, one], [{ response: 'ok', paths: ['/home/caboose/a'], extra: 1 }, one],
      [{ response: 'ok', paths: Array.from({ length: 65 }, (_, n) => `/home/caboose/${n}`) }, { ...one, multiple: true }],
    ] as const) expect(() => parseBridgeAnswer(open.id, body as Record<string, unknown>, request), JSON.stringify(body)).toThrow(BridgeInputError)
  })
})

describe('parseAppearance and parseLocation', () => {
  const appearance = { colorScheme: 'dark', accent: '#0A84FF', contrast: 'normal', reducedMotion: false, textScale: 1 }
  it('accepts exactly the contract', () => {
    expect(parseAppearance(appearance)).toEqual(appearance)
    expect(parseLocation({ latitude: 43.65, longitude: -79.38, accuracy: 12 })).toEqual({ latitude: 43.65, longitude: -79.38, accuracy: 12, altitude: null })
    expect(parseLocation({ latitude: -90, longitude: 180, accuracy: 0, altitude: 76.5 }).altitude).toBe(76.5)
  })
  it('rejects anything else', () => {
    for (const bad of [
      {}, { ...appearance, colorScheme: 'auto' }, { ...appearance, accent: 'blue' }, { ...appearance, accent: '#0A84F' },
      { ...appearance, contrast: 'more' }, { ...appearance, reducedMotion: 0 }, { ...appearance, textScale: 0.5 },
      { ...appearance, textScale: 3 }, { ...appearance, textScale: Number.NaN }, { ...appearance, theme: 'x' },
    ]) expect(() => parseAppearance(bad as Record<string, unknown>), JSON.stringify(bad)).toThrow(BridgeInputError)
    for (const bad of [
      {}, { latitude: 91, longitude: 0, accuracy: 1 }, { latitude: 0, longitude: -181, accuracy: 1 }, { latitude: 0, longitude: 0, accuracy: -1 },
      { latitude: 0, longitude: 0, accuracy: 100_001 }, { latitude: 0, longitude: 0, accuracy: 1, altitude: -2000 },
      { latitude: '1', longitude: 0, accuracy: 1 }, { latitude: 0, longitude: 0, accuracy: 1, speed: 3 },
    ]) expect(() => parseLocation(bad as Record<string, unknown>), JSON.stringify(bad)).toThrow(BridgeInputError)
  })
})

describe('BridgeRelay', () => {
  it('delivers each request once, withdraws cancelled ones, and returns malformed ones to the computer', async () => {
    const fake = fakeGuest()
    const events: BridgeEvent[] = []
    const relay = new BridgeRelay(() => fake.guest, event => events.push(event), 60_000)
    fake.drain({ requests: [open, { ...save, title: 'bad\u0007' }], cancels: [] })
    await relay.poll()
    expect(events).toEqual([{ type: 'bridge.request', request: open }])
    expect(relay.pending(open.id)).toBe(true)
    expect(fake.bridgeCalls('respond').map(call => JSON.parse(call.at(-1)!))).toEqual([{ id: save.id, response: 'computer' }])
    fake.drain({ requests: [open], cancels: [] })
    await relay.poll()
    expect(events).toHaveLength(1)
    fake.drain({ requests: [], cancels: [open.id, 'not-an-id'] })
    await relay.poll()
    expect(events.at(-1)).toEqual({ type: 'bridge.cancel', id: open.id })
    expect(relay.pending(open.id)).toBe(false)
  })

  it('ignores drain output that is not the contract', async () => {
    const fake = fakeGuest()
    const events: BridgeEvent[] = []
    const relay = new BridgeRelay(() => fake.guest, event => events.push(event), 60_000)
    for (const output of ['', 'nope', '[]', JSON.stringify({ requests: Array(17).fill(open), cancels: [] }), JSON.stringify({ requests: [open] })]) {
      fake.drain(output)
      await relay.poll()
    }
    expect(events).toEqual([])
  })

  it('answers through the guest, once, and withdraws the request from the other phones', async () => {
    const fake = fakeGuest()
    const events: [BridgeEvent, string | undefined][] = []
    const relay = new BridgeRelay(() => fake.guest, (event, except) => events.push([event, except]), 60_000)
    fake.drain({ requests: [open], cancels: [] })
    await relay.poll()
    await relay.answer(open.id, { response: 'ok', paths: ['/home/caboose/Documents/a.odt'], filter: 0 }, 'phone-1')
    expect(fake.bridgeCalls('respond').map(call => JSON.parse(call.at(-1)!))).toEqual([{ id: open.id, response: 'ok', paths: ['/home/caboose/Documents/a.odt'], filter: 0 }])
    expect(events.at(-1)).toEqual([{ type: 'bridge.cancel', id: open.id }, 'phone-1'])
    await expect(relay.answer(open.id, { response: 'cancel' })).rejects.toThrow(AgentNotFoundError)
    await expect(relay.answer('0'.repeat(32), { response: 'cancel' })).rejects.toThrow(AgentNotFoundError)
    await expect(relay.answer('../x', { response: 'cancel' })).rejects.toThrow(AgentNotFoundError)
  })

  it('keeps a request open when the guest fails, and reports one the guest no longer has', async () => {
    const fake = fakeGuest()
    const events: BridgeEvent[] = []
    const relay = new BridgeRelay(() => fake.guest, event => events.push(event), 60_000)
    fake.drain({ requests: [open, save], cancels: [] })
    await relay.poll()
    fake.onRespond(() => { throw new Error('Guest command failed: busy') })
    await expect(relay.answer(open.id, { response: 'cancel' })).rejects.toThrow(AgentOperationError)
    expect(relay.pending(open.id)).toBe(true)
    fake.onRespond(() => '{"answered":false}')
    await expect(relay.answer(save.id, { response: 'cancel' })).rejects.toThrow(AgentNotFoundError)
    expect(events.at(-1)).toEqual({ type: 'bridge.cancel', id: save.id })
    // An invalid answer leaves the request open for a valid one.
    await expect(relay.answer(open.id, { response: 'ok', paths: ['/etc/x'] })).rejects.toThrow(BridgeInputError)
    expect(relay.pending(open.id)).toBe(true)
  })

  it('forgets requests after 24 hours and when the computer stops', async () => {
    const fake = fakeGuest()
    let now = 1_000
    const relay = new BridgeRelay(() => fake.guest, () => {}, 60_000, () => now)
    fake.drain({ requests: [open], cancels: [] })
    await relay.poll()
    now += OUTSTANDING_MS
    expect(relay.pending(open.id)).toBe(false)
    fake.drain({ requests: [save], cancels: [] })
    await relay.poll()
    relay.computerStopped()
    expect(relay.pending(save.id)).toBe(false)
  })

  it('delivers nothing from a drain that outlives the computer, and does not reopen a stopped request', async () => {
    const fake = fakeGuest()
    const events: BridgeEvent[] = []
    let finishDrain: (output: string) => void = () => {}
    const slow: AgentGuest = { run: (command, args) => args.includes('drain') ? new Promise(resolve => { finishDrain = resolve }) : fake.guest.run(command, args) }
    const late = new BridgeRelay(() => slow, event => events.push(event), 60_000)
    const polling = late.poll()
    late.computerStopped()
    finishDrain(JSON.stringify({ requests: [open], cancels: [] }))
    await polling
    expect(events).toEqual([])
    expect(late.pending(open.id)).toBe(false)

    let failRespond: (error: Error) => void = () => {}
    const failing: AgentGuest = { run: (command, args) => args.includes('respond') ? new Promise((_, reject) => { failRespond = reject }) : fake.guest.run(command, args) }
    const stopped = new BridgeRelay(() => failing, () => {}, 60_000)
    fake.drain({ requests: [save], cancels: [] })
    await stopped.poll()
    const answering = stopped.answer(save.id, { response: 'cancel' })
    stopped.computerStopped()
    failRespond(new Error('Guest command failed: gone'))
    await expect(answering).rejects.toThrow(AgentOperationError)
    expect(stopped.pending(save.id)).toBe(false)
  })

  it('applies the stored appearance', async () => {
    const fake = fakeGuest()
    const relay = new BridgeRelay(() => fake.guest, () => {}, 60_000)
    await relay.applyAppearance()
    expect(fake.bridgeCalls('appearance')).toEqual([])
    relay.appearance = parseAppearance({ colorScheme: 'light', accent: '#FF9500', contrast: 'high', reducedMotion: true, textScale: 1.25 })
    await relay.applyAppearance()
    expect(fake.bridgeCalls('appearance').map(call => JSON.parse(call.at(-1)!))).toEqual([relay.appearance])
    expect(fake.calls[0]!.slice(0, 4)).toEqual(['/usr/sbin/runuser', '-u', 'caboose', '--'])
  })

  it('does not fork idle drains while active', async () => {
    vi.useFakeTimers()
    try {
      const fake = fakeGuest()
      const relay = new BridgeRelay(() => fake.guest, () => {}, 1000)
      relay.setActive(true)
      await vi.advanceTimersByTimeAsync(3000)
      const drains = fake.bridgeCalls('drain').length
      expect(drains).toBe(0)
      relay.setActive(false)
      await vi.advanceTimersByTimeAsync(3000)
      expect(fake.bridgeCalls('drain')).toHaveLength(drains)
    } finally { vi.useRealTimers() }
  })
})

describe('LocationShare', () => {
  afterEach(() => { vi.useRealTimers() })

  it('writes GeoClue\'s static source file as root, at most every 5 seconds, and expires it', async () => {
    vi.useFakeTimers()
    const fake = fakeGuest()
    let now = 100_000
    const share = new LocationShare(() => fake.guest, () => now)
    await share.set({ latitude: 43.65, longitude: -79.38, accuracy: 12, altitude: null })
    const write = fake.calls.find(call => call.includes(GEOLOCATION_WRITE_SCRIPT))!
    expect(write[0]).toBe('/bin/sh')
    expect(write.at(-1)).toBe(`43.65\n-79.38\n${-Number.MAX_VALUE}\n12\n`)
    await expect(share.set({ latitude: 1, longitude: 1, accuracy: 1, altitude: 3 })).rejects.toThrow(BridgeRateLimitError)
    now += 5000
    await share.set({ latitude: 1, longitude: 1, accuracy: 1, altitude: 3 })
    expect(share.sharing).toBe(true)
    await vi.advanceTimersByTimeAsync(LOCATION_EXPIRY_MS)
    expect(fake.calls.at(-1)).toEqual(['/bin/rm', '-f', '--', GEOLOCATION_FILE])
    expect(share.sharing).toBe(false)
  })

  it('removes the file when sharing stops or the computer runs again', async () => {
    const fake = fakeGuest()
    const share = new LocationShare(() => fake.guest)
    await share.set({ latitude: 0, longitude: 0, accuracy: 5, altitude: null })
    await share.clear()
    expect(share.sharing).toBe(false)
    await share.computerRunning()
    expect(fake.calls.filter(call => call[0] === '/bin/rm')).toHaveLength(2)
  })

  it('formats every field on its own line', () => {
    expect(geolocationFile({ latitude: -33.86, longitude: 151.21, accuracy: 30, altitude: 58 })).toBe('-33.86\n151.21\n58\n30\n')
  })
})
