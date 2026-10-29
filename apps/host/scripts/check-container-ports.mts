#!/usr/bin/env -S node --import tsx
// Real Docker check. Uses an already-present Node image and removes only its own containers.
import assert from 'node:assert/strict'
import { randomBytes } from 'node:crypto'
import { containerPlacement, dockerCli, withContainerPorts } from '../src/container-driver.js'

const docker = dockerCli()
const suffix = randomBytes(6).toString('hex')
const legacy = `caboose-port-check-legacy-${suffix}`
const high = `caboose-port-check-high-${suffix}`
const image = process.env.CABOOSE_CHECK_IMAGE ?? 'node:22-bookworm-slim'
const owned: string[] = []
const placement = containerPlacement({ containerName: 'owner', containerHome: 'home' }, { id: 'c-0123456789', slot: 64 })
assert.equal(placement.ports.display, 0)
assert.equal(placement.bridge, 'caboose-br64')
try {
  await docker(['image', 'inspect', image])
  await docker(['create', '--name', legacy, '-p', '127.0.0.1:20010:14600', image, 'node', '-e', 'setInterval(()=>{},1000)'])
  owned.push(legacy)
  await docker(['start', legacy])
  const assigned = await withContainerPorts(docker, async ports => {
    await docker(['create', '--name', high, '-p', `127.0.0.1:${ports.display}:14600`, '-p', `127.0.0.1:${ports.agent}:14601`, '-p', `127.0.0.1:${ports.files}:14700`, '-p', `127.0.0.1:${ports.terminal}:14701`, image, 'node', '-e', 'setInterval(()=>{},1000)'])
    owned.push(high)
    await docker(['start', high])
    return ports
  })
  for (const [guest, port] of [[14600, assigned.display], [14601, assigned.agent], [14700, assigned.files], [14701, assigned.terminal]]) {
    assert.equal((await docker(['port', high, `${guest}/tcp`])).trim(), `127.0.0.1:${port}`)
    assert.ok(port > 20633 && port <= 65535)
  }
  await docker(['stop', high])
  const next = await withContainerPorts(docker, async ports => ports)
  assert.ok(!Object.values(next).some(port => Object.values(assigned).includes(port)))
  await docker(['start', high])
  assert.equal((await docker(['port', high, '14600/tcp'])).trim(), `127.0.0.1:${assigned.display}`)
  console.log(`Legacy port 20010 and high-slot ports ${Object.values(assigned).join(', ')} coexist; stopped bindings remained reserved and restart preserved them.`)
} finally {
  const failures: unknown[] = []
  for (const name of owned.reverse()) await docker(['rm', '-f', name]).catch(error => failures.push(error))
  if (failures.length) throw new AggregateError(failures, 'Could not remove Docker check containers')
}
