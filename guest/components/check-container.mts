import assert from 'node:assert/strict'
import { execFileSync } from 'node:child_process'
import { randomUUID } from 'node:crypto'
import { fileURLToPath } from 'node:url'
import { upgradeComponents, readBundle, prepareContainerSession, type UpgradeStatus } from '../../apps/host/src/components.js'
import type { AgentGuest } from '../../apps/host/src/agents.js'

const name = `caboose-upgrade-check-${randomUUID().slice(0, 8)}`
const docker = (...args: string[]) => execFileSync('docker', args, { encoding: 'utf8', timeout: 900_000, stdio: ['ignore', 'pipe', 'inherit'] })
try {
  const source = fileURLToPath(new URL('..', import.meta.url))
  docker('run', '-d', '--name', name, '-v', `${source}:/bundle:ro`, 'debian:trixie-slim', 'sleep', 'infinity')
  const run = (command: string, args: string[]) => docker('exec', '-u', 'root', name, command, ...args)
  run('/bin/sh', ['-c', 'apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends python3 iproute2 dbus && useradd -m -u 1000 caboose && mkdir -p /home/caboose/Documents /run/caboose && echo keep > /home/caboose/Documents/sentinel && echo token > /run/caboose/xpra-token && chown caboose:caboose /run/caboose/xpra-token'])
  run('/bin/sh', ['-c', `mkdir -p /etc/xdg/Thunar /home/caboose/.config/Thunar; printf '%s' '<actions><action><unique-id>existing</unique-id></action></actions>' > /etc/xdg/Thunar/uca.xml; printf '%s' owner-custom > /home/caboose/.config/Thunar/uca.xml`])
  const guest: AgentGuest = { run: async (cmd, args) => run(cmd, args) }
  await prepareContainerSession(guest)
  run('/usr/local/bin/caboose-session', ['start-printing'])
  run('/bin/sh', ['-c', 'echo 1 > /run/caboose/files.pid'])
  const events: UpgradeStatus[] = []
  const bundle = await readBundle()
  await upgradeComponents(guest, 'container', s => events.push(s), bundle)
  assert.equal(events.at(-1)?.state, 'succeeded', JSON.stringify(events.at(-1)))
  assert.equal(run('/bin/cat', ['/home/caboose/Documents/sentinel']).trim(), 'keep')
  assert.equal(run('/bin/cat', ['/home/caboose/.config/Thunar/uca.xml']).trim(), 'owner-custom')
  const actions = run('/bin/cat', ['/etc/xdg/Thunar/uca.xml'])
  assert.match(actions, /<unique-id>existing<\/unique-id>/)
  assert.match(actions, /<unique-id>caboose-share-to-iphone<\/unique-id>/)
  assert.equal(run('/bin/cat', ['/usr/local/share/caboose/components.version']).trim(), bundle.version)
  run('/bin/sh', ['-c', 'test -x /usr/local/bin/caboose-open && test -f /opt/caboose/files/caboose-files.py && test -f /opt/caboose/notifications/monitor.py && lpstat -p iPhone && ss -lnt | grep -q :14700'])
  run('/bin/bash', ['/bundle/components/install.sh', 'container'])
  assert.equal(run('/bin/cat', ['/home/caboose/Documents/sentinel']).trim(), 'keep')
  const repeated: UpgradeStatus[] = []
  await upgradeComponents(guest, 'container', s => repeated.push(s), bundle)
  assert.deepEqual(repeated.map(s => s.state), ['checking', 'succeeded'])
  run('/usr/sbin/lpadmin', ['-p', 'iPhone', '-v', 'socket://localhost', '-E'])
  assert.throws(() => run('/usr/local/libexec/caboose-phone-printer-setup', []))
  assert.match(run('/usr/bin/lpstat', ['-v', 'iPhone']), /socket:\/\/localhost/)
  console.log('Guest upgrade, services, user-data preservation, printer conflict, and repeat check passed.')
} finally {
  try { docker('rm', '-f', name) } catch { /* Container may not have been created. */ }
}
