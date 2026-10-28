import { describe, expect, it, vi } from 'vitest'
import { HOME_REPAIR_SCRIPT, HomeOwnership } from './home.js'

function guest(output = '0') {
  const run = vi.fn(async (_command: string, _args: string[]) => output)
  return { run }
}

describe('home ownership repair', () => {
  it('gives the home back to caboose as root, at most once per interval', async () => {
    let now = 1_000
    const home = new HomeOwnership(60_000, () => now)
    const fake = guest('3\n')
    expect(await home.ensure(fake)).toBe(3)
    expect(fake.run).toHaveBeenCalledWith('/bin/sh', ['-c', HOME_REPAIR_SCRIPT], 90_000)
    now += 30_000
    expect(await home.ensure(fake)).toBe(0)
    expect(fake.run).toHaveBeenCalledTimes(1)
    now += 31_000
    await home.ensure(fake)
    expect(fake.run).toHaveBeenCalledTimes(2)
    home.reset()
    await home.ensure(fake)
    expect(fake.run).toHaveBeenCalledTimes(3)
  })

  it('never blocks the operation when the check fails', async () => {
    const home = new HomeOwnership()
    const error = vi.spyOn(console, 'error').mockImplementation(() => {})
    expect(await home.ensure({ run: async () => { throw new Error('find: timed out') } })).toBe(0)
    expect(error).toHaveBeenCalled()
    error.mockRestore()
  })

  it('only changes entries under the home, on its own filesystem, and both owner and group', () => {
    expect(HOME_REPAIR_SCRIPT).toContain('find /home/caboose -xdev')
    expect(HOME_REPAIR_SCRIPT).toContain('! -user caboose -o ! -group caboose')
    expect(HOME_REPAIR_SCRIPT).toContain('chown -h caboose:caboose')
  })
})
