import { test } from 'node:test'
import assert from 'node:assert/strict'
import { seatStarter } from './ensure-agent-seat.mjs'

test('coalesces concurrent seat starts and retries after failure', async () => {
  const calls = []
  let fail = true
  const start = seatStarter(async (command, args) => {
    calls.push([command, args])
    if (command === 'sudo' && fail) { fail = false; throw new Error('unavailable') }
    return { stdout: command === '/usr/bin/python3' ? 'DISPLAY=:101\0WAYLAND_DISPLAY=wayland-agent\0' : '' }
  })
  await assert.rejects(start(), /unavailable/)
  const [a, b] = await Promise.all([start(), start()])
  assert.deepEqual(a, { DISPLAY: ':101', WAYLAND_DISPLAY: 'wayland-agent' })
  assert.deepEqual(b, a)
  assert.equal(calls.filter(([command]) => command === 'sudo').length, 2)
})
