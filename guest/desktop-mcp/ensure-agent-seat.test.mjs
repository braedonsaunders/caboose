import { test } from 'node:test'
import assert from 'node:assert/strict'
import { seatStarter } from './ensure-agent-seat.mjs'

test('coalesces concurrent seat starts and retries after failure', async () => {
  const calls = []
  let fail = true
  const start = seatStarter(async (command, args) => {
    calls.push([command, args])
    if (command === 'sudo' && fail) { fail = false; throw new Error('unavailable') }
    return { stdout: command === '/bin/sh' ? 'DISPLAY=:101\0WAYLAND_DISPLAY=wayland-agent\0' : '' }
  })
  await assert.rejects(start(), /unavailable/)
  const [a, b] = await Promise.all([start(), start()])
  assert.deepEqual(a, { DISPLAY: ':101', WAYLAND_DISPLAY: 'wayland-agent' })
  assert.deepEqual(b, a)
  assert.equal(calls.filter(([command]) => command === 'sudo').length, 2)
})

test('caches a healthy seat and recovers after its socket dies', async () => {
  let sudo = 0, reads = 0, healthy = true
  const start = seatStarter(async command => {
    if (command === 'sudo') { sudo++; healthy = true }
    else reads++
    return { stdout: 'CABOOSE_DISPLAY_CONTROL=/test/control.sock\0' }
  }, async () => healthy, () => false)
  await start()
  await Promise.all([start(), start()])
  assert.equal(sudo, 1)
  assert.equal(reads, 1)
  healthy = false
  await start()
  assert.equal(sudo, 2)
  assert.equal(reads, 2)
})

test('adopts an existing live environment without sudo', async () => {
  const start = seatStarter(async command => {
    assert.equal(command, '/bin/sh')
    return { stdout: 'CABOOSE_DISPLAY_CONTROL=/existing/control.sock\0' }
  }, async () => true, () => true)
  assert.equal((await start()).CABOOSE_DISPLAY_CONTROL, '/existing/control.sock')
})

test('health checks require an ok control response and handle a vanished socket', async () => {
  const { createServer } = await import('node:net')
  const { mkdtemp, rm } = await import('node:fs/promises')
  const { controlAlive } = await import('./ensure-agent-seat.mjs')
  const dir = await mkdtemp('/tmp/caboose-health-')
  const path = `${dir}/control.sock`
  let ok = true
  const server = createServer(socket => socket.once('data', data => {
    assert.equal(data.toString(), 'windows\n')
    socket.end(JSON.stringify({ ok }) + '\n')
  }))
  await new Promise(resolve => server.listen(path, resolve))
  try {
    assert.equal(await controlAlive({ CABOOSE_DISPLAY_CONTROL: path }), true)
    ok = false
    assert.equal(await controlAlive({ CABOOSE_DISPLAY_CONTROL: path }), false)
    await new Promise(resolve => server.close(resolve))
    assert.equal(await controlAlive({ CABOOSE_DISPLAY_CONTROL: path }), false)
  } finally { server.close(); await rm(dir, { recursive: true, force: true }) }
})
