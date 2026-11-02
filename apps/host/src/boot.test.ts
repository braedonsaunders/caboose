import { describe, expect, it } from 'vitest'
import { BOOT_STEPS, BootProgress, formatBytes, type Boot } from './boot.js'

const states = (boot: Boot | null) => boot?.steps.map(step => `${step.id}:${step.state}`)

describe('BootProgress', () => {
  it('follows the steps as they are reported, and marks the ones never reached as not needed', () => {
    const progress = new BootProgress(BOOT_STEPS.container, () => new Date('2026-11-01T12:00:00Z'))
    const seen: Boot[] = []
    progress.subscribe(boot => seen.push(boot))
    // Reports outside a boot are ignored.
    progress.report('network')
    expect(progress.get()).toBeNull()

    progress.begin()
    expect(states(progress.get())).toEqual(['image:pending', 'network:pending', 'disk:pending', 'start:pending', 'display:pending'])
    progress.report('image', { detail: '1.0 GB of 2.0 GB', progress: { completed: 1e9, total: 2e9 } })
    progress.report('network')
    expect(progress.get()!.steps[0]).toMatchObject({ state: 'done', progress: { completed: 2e9, total: 2e9 } })
    // The container already existed: no disk was made.
    progress.report('start')
    progress.report('display')
    progress.succeed()
    expect(states(progress.get())).toEqual(['image:done', 'network:done', 'disk:skipped', 'start:done', 'display:done'])
    expect(progress.get()).toMatchObject({ state: 'succeeded', error: null, startedAt: '2026-11-01T12:00:00.000Z', finishedAt: '2026-11-01T12:00:00.000Z' })
    expect(seen.length).toBe(6)
    // A finished boot takes no more reports.
    progress.report('image')
    expect(seen.length).toBe(6)
  })

  it('fails at the step under way and says why, and a new boot starts clean', () => {
    const progress = new BootProgress(BOOT_STEPS.microvm)
    const first = progress.begin()
    expect(progress.begin().id).toBe(first.id)
    progress.report('network')
    progress.report('start')
    progress.fail('The computer did not answer within 2 minutes')
    expect(states(progress.get())).toEqual(['image:skipped', 'network:done', 'start:failed', 'display:pending'])
    expect(progress.get()).toMatchObject({ state: 'failed', error: 'The computer did not answer within 2 minutes' })
    progress.succeed()
    expect(progress.get()!.state).toBe('failed')
    const retry = progress.begin()
    expect(retry.id).not.toBe(first.id)
    expect(states(retry)).toEqual(['image:pending', 'network:pending', 'start:pending', 'display:pending'])
  })

  it('fails the first step when nothing was under way, and ignores steps its runtime does not take', () => {
    const progress = new BootProgress(BOOT_STEPS.microvm)
    progress.begin()
    progress.report('disk')
    expect(states(progress.get())).toEqual(['image:pending', 'network:pending', 'start:pending', 'display:pending'])
    progress.fail("The computer's image is not installed")
    expect(states(progress.get())![0]).toBe('image:failed')
  })

  it('hands out copies', () => {
    const progress = new BootProgress()
    progress.begin()
    progress.get()!.steps[0]!.state = 'done'
    expect(progress.get()!.steps[0]!.state).toBe('pending')
  })
})

it('formats byte counts for people', () => {
  expect(formatBytes(512)).toBe('512 B')
  expect(formatBytes(1_234_000_000)).toBe('1.2 GB')
  expect(formatBytes(345_000_000)).toBe('345 MB')
})
