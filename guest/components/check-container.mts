import assert from 'node:assert/strict'
import { execFileSync } from 'node:child_process'
import { randomUUID } from 'node:crypto'
import { fileURLToPath } from 'node:url'
import { upgradeComponents, readBundle, guardContainerPrinting, type UpgradeStatus } from '../../apps/host/src/components.js'
import type { AgentGuest } from '../../apps/host/src/agents.js'

const name = `caboose-upgrade-check-${randomUUID().slice(0, 8)}`
const docker = (...args: string[]) => execFileSync('docker', args, { encoding: 'utf8', timeout: 900_000, stdio: ['ignore', 'pipe', 'inherit'] })
try {
  const source = fileURLToPath(new URL('..', import.meta.url))
  docker('run', '-d', '--name', name, '-v', `${source}:/bundle:ro`, 'debian:trixie-slim', 'sleep', 'infinity')
  const run = (command: string, args: string[]) => docker('exec', '-u', 'root', name, command, ...args)
  run('/bin/sh', ['-c', 'apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends python3 dbus && useradd -m -u 1000 caboose && mkdir -p /home/caboose/Documents /run/caboose && echo keep > /home/caboose/Documents/sentinel && printf %s token > /run/caboose/display-token && chown caboose:caboose /run/caboose/display-token'])
  run('/bin/sh', ['-c', `mkdir -p /etc/xdg/Thunar /home/caboose/.config/Thunar; printf '%s' '<actions><action><unique-id>existing</unique-id></action></actions>' > /etc/xdg/Thunar/uca.xml; printf '%s' owner-custom > /home/caboose/.config/Thunar/uca.xml`])
  const guest: AgentGuest = { run: async (cmd, args) => run(cmd, args) }
  run('/bin/sh', ['-c', `printf '%s\n' '#!/bin/bash' 'start_printing() {' '  /usr/local/libexec/caboose-phone-printer-setup' '}' 'start_printing; true' > /usr/local/bin/caboose-session`])
  await guardContainerPrinting(guest)
  await guardContainerPrinting(guest)
  run('/bin/bash', ['/usr/local/bin/caboose-session'])
  run('/bin/sh', ['-c', 'install -d -o caboose -g caboose -m 0700 /run/user/1000; runuser -u caboose -- dbus-daemon --session --address=unix:path=/run/user/1000/bus --fork; echo 1 > /run/caboose/files.pid'])
  const events: UpgradeStatus[] = []
  const bundle = await readBundle()
  await upgradeComponents(guest, 'container', s => events.push(s), bundle)
  assert.equal(events.at(-1)?.state, 'succeeded', JSON.stringify(events.at(-1)))
  assert.match(run('/usr/bin/node', ['/opt/caboose/agentd/caboose-agentd.mjs', '--version']), /0\.1\.0/)
  assert.equal(run('/bin/cat', ['/opt/caboose/agentd/caboose-agentd.mjs']), run('/bin/cat', ['/bundle/agentd/caboose-agentd.mjs']))
  assert.equal(run('/bin/cat', ['/home/caboose/Documents/sentinel']).trim(), 'keep')
  assert.equal(run('/bin/cat', ['/home/caboose/.config/Thunar/uca.xml']).trim(), 'owner-custom')
  const actions = run('/bin/cat', ['/etc/xdg/Thunar/uca.xml'])
  assert.match(actions, /<unique-id>existing<\/unique-id>/)
  assert.match(actions, /<unique-id>caboose-share-to-iphone<\/unique-id>/)
  assert.equal(run('/bin/cat', ['/usr/local/share/caboose/components.version']).trim(), bundle.version)
  run('/bin/sh', ['-c', 'test -x /usr/local/bin/caboose-open && test -f /opt/caboose/files/caboose-files.py && test -f /opt/caboose/notifications/monitor.py && lpstat -p iPhone && grep -Eq "^ *[0-9]+: [0-9A-F]+:396C [0-9A-F]+:[0-9A-F]+ 0A " /proc/net/tcp /proc/net/tcp6'])
  // The terminal service listens on 14701 as the owner, and answers only the token.
  run('/bin/sh', ['-c', 'grep -Eq "^ *[0-9]+: [0-9A-F]+:396D [0-9A-F]+:[0-9A-F]+ 0A " /proc/net/tcp /proc/net/tcp6 && test "$(stat -c %u /proc/$(cat /run/caboose/terminal.pid))" = 1000'])
  assert.match(run('/usr/bin/python3', ['-c', `import urllib.request, urllib.error
try: urllib.request.urlopen('http://127.0.0.1:14701/sessions')
except urllib.error.HTTPError as e: print(e.code)`]), /401/)
  assert.equal(run('/usr/bin/python3', ['-c', `import urllib.request; print(urllib.request.urlopen(urllib.request.Request('http://127.0.0.1:14701/sessions', headers={'Authorization': 'Bearer token'})).read().decode())`]).trim(), '{"sessions": []}')
  run('/bin/sh', ['-c', 'runuser -u caboose -- env DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus /usr/bin/python3 /opt/caboose/notifications/daemon.py >/tmp/notification-endpoint.log 2>&1 < /dev/null & sleep 1'])
  run('/bin/sh', ['-c', `runuser -u caboose -- env DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus notify-send caboose-upgrade-check hello || true; for i in $(seq 1 20); do grep -ql caboose-upgrade-check /home/caboose/.cache/caboose/notifications/*.json 2>/dev/null && exit 0; sleep 0.5; done; echo 'Notification monitor did not receive a message' >&2; exit 1`])
  // Replace a stale runner through the same upgrade bundle without recreating the computer.
  run('/bin/sh', ['-c', 'printf stale > /opt/caboose/agentd/caboose-agentd.mjs'])
  run('/bin/bash', ['/bundle/components/install.sh', 'container'])
  assert.match(run('/usr/bin/node', ['/opt/caboose/agentd/caboose-agentd.mjs', '--version']), /0\.1\.0/)
  assert.equal(run('/bin/cat', ['/opt/caboose/agentd/caboose-agentd.mjs']), run('/bin/cat', ['/bundle/agentd/caboose-agentd.mjs']))
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
