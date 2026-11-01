import { describe, expect, it } from 'vitest'
import { appsBusy } from './busy.js'

const io = (read = 0, write = 0) => ({ readBytesPerSecond: read, writeBytesPerSecond: write })
const app = (kind: 'app' | 'session', cpuPercent: number, rw = io()) => ({ kind, cpuPercent, io: rw }) as never

describe('apps at work', () => {
  it('counts an app using CPU or disk, not an idle one or Caboose’s session', () => {
    expect(appsBusy({ apps: [app('app', 0.5), app('session', 40)], services: [] })).toBe(false)
    expect(appsBusy({ apps: [app('app', 12)], services: [] })).toBe(true)
    expect(appsBusy({ apps: [app('app', 0, io(0, 4 * 1024 * 1024))], services: [] })).toBe(true)
  })
  it('counts an active service at work', () => {
    expect(appsBusy({ apps: [], services: [{ state: 'active', cpuPercent: 30, io: io() } as never] })).toBe(true)
    expect(appsBusy({ apps: [], services: [{ state: 'failed', cpuPercent: 30, io: io() } as never] })).toBe(false)
  })
})
