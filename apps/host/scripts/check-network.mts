#!/usr/bin/env -S node --import tsx
// Real-host check of a computer as a network machine (docs/network.md): a throwaway container
// computer on its own fenced bridge gets its own tailnet device through the production
// companion, caboose-ports puts its loopback servers on that address, and the fence still
// keeps the computer out of the tailnet. It touches only what it creates.
//
//   CABOOSE_CHECK_IMAGE=caboose-computer:<tag> apps/host/node_modules/.bin/tsx apps/host/scripts/check-network.mts [--vite] [--postgres] [--keep]
//
// Needs Docker, /dev/net/tun, and root or `sudo -n` for the fence. The device joins the way the
// host would (tailnet.ts): CABOOSE_TAILSCALE_AUTHKEY, an OAuth client, or a sign-in link this
// check prints and waits 30 minutes for (CABOOSE_CHECK_SIGN_IN_MS). Then run check-network-client.mjs from another
// tailnet machine with the name it prints; --keep leaves everything up for that, and a second
// run with CABOOSE_CHECK_REMOVE=<suffix> removes it.
import assert from 'node:assert/strict'
import { randomBytes } from 'node:crypto'
import { dockerCli } from '../src/container-driver.js'
import { allowCompanion, fenceBridge, unfenceBridge } from '../src/network.js'
import { readNetworkActivity } from '../src/network-activity.js'
import { TailnetNode, dockerInputCli, tailnetConfig } from '../src/tailnet.js'

const docker = dockerCli()
const args = new Set(process.argv.slice(2))
const suffix = process.env.CABOOSE_CHECK_REMOVE ?? randomBytes(3).toString('hex')
const computer = `caboose-check-net-${suffix}`, network = `caboose-check-${suffix}`, bridge = `cbchk${suffix}`
const image = process.env.CABOOSE_CHECK_IMAGE ?? 'caboose-computer:latest'
const config = tailnetConfig({ ...process.env, CABOOSE_TAILNET: 'on' })
assert.notEqual(config.mode, 'off')
const node = new TailnetNode({ config: config as Exclude<typeof config, { mode: 'off' }>, docker, dockerInput: dockerInputCli(), name: `${computer}-net`, computer, network,
  hostname: () => `caboose-check-${suffix}`, allow: (companion, target) => allowCompanion(bridge, companion, target) })
const exec = (user: 'root' | 'caboose', script: string, timeoutMs = 60_000) => docker(['exec', '-u', user, computer, '/bin/sh', '-c', script], timeoutMs)

async function remove(): Promise<void> {
  await node.destroy()
  await docker(['rm', '-f', computer], 60_000).catch(() => {})
  await docker(['network', 'rm', network], 30_000).catch(() => {})
  await unfenceBridge(bridge)
}

if (process.env.CABOOSE_CHECK_REMOVE) { await remove(); console.log(`Removed ${computer}.`); process.exit(0) }

let passed = false
try {
  await docker(['image', 'inspect', image], 15_000)
  await docker(['network', 'create', '--driver', 'bridge', '-o', `com.docker.network.bridge.name=${bridge}`, network], 30_000)
  await fenceBridge(bridge)
  await docker(['run', '-d', '--name', computer, '--init', '--network', network, '--dns', '1.1.1.1', '--memory', '3g', '--cpus', '2', image], 120_000)
  // The forwarder from this checkout, with its switch where the host writes it.
  await docker(['cp', new URL('../../../guest/ports/caboose-ports.py', import.meta.url).pathname, `${computer}:/opt/caboose-ports.py`], 30_000)
  await exec('root', 'install -d -m 0755 /run/caboose && echo \'{"forward": true}\' > /run/caboose/ports.json')
  await docker(['exec', '-d', '-u', 'caboose', computer, 'python3', '/opt/caboose-ports.py'], 15_000)

  let status = await node.ensure()
  if (status.state === 'needs-login') console.log(`Sign the check's device in to your tailnet: ${status.loginUrl}`)
  for (const deadline = Date.now() + Number(process.env.CABOOSE_CHECK_SIGN_IN_MS ?? 1_800_000); status.state !== 'running' && Date.now() < deadline;) {
    assert.ok(status.state !== 'error', status.error)
    await new Promise(resolve => setTimeout(resolve, 3000))
    const link = status.loginUrl
    status = await node.refresh()
    if (status.loginUrl && status.loginUrl !== link) console.log(`The sign-in link changed: ${status.loginUrl}`)
  }
  assert.equal(status.state, 'running', `The device did not join: ${JSON.stringify(status)}`)
  assert.ok(status.name && status.addresses?.[0], 'The device has no name or address')
  console.log(`Device ${status.name} (${status.addresses!.join(', ')})`)

  // Loopback-only servers, as dev tools start them, and one on every address.
  await exec('caboose', 'mkdir -p /tmp/site && echo "<title>Hello from the computer</title>" > /tmp/site/index.html && cd /tmp/site && (nohup python3 -m http.server --bind 127.0.0.1 8000 >/dev/null 2>&1 &) && (nohup python3 -m http.server --bind 0.0.0.0 8001 >/dev/null 2>&1 &)')
  if (args.has('--vite')) {
    await exec('caboose', 'cd /tmp && nice -n 19 npm create -y vite@latest app -- --template vanilla >/dev/null 2>&1 && cd app && nice -n 19 npm install --no-audit --no-fund >/dev/null 2>&1', 900_000)
    await exec('caboose', 'cd /tmp/app && (nohup npx vite --port 5173 --strictPort >/tmp/vite.log 2>&1 &)')
  }
  if (args.has('--postgres')) {
    await exec('root', 'export DEBIAN_FRONTEND=noninteractive; nice -n 19 apt-get update -qq && nice -n 19 apt-get install -y -qq postgresql >/dev/null', 900_000)
    await exec('root', 'pg_ctlcluster $(ls /etc/postgresql) main start && runuser -u postgres -- psql -qc "ALTER USER postgres PASSWORD \'caboose-check\'"', 120_000)
  }
  const expected = [8000, 8001, ...(args.has('--vite') ? [5173] : []), ...(args.has('--postgres') ? [5432] : [])]
  const guest = { run: (command: string, argv: string[], timeoutMs?: number) => docker(['exec', '-u', 'root', computer, command, ...argv], timeoutMs) }
  let servers: number[] = []
  for (const deadline = Date.now() + 60_000; Date.now() < deadline; await new Promise(resolve => setTimeout(resolve, 1000))) {
    servers = (await readNetworkActivity(guest)).servers.map(server => server.port)
    if (expected.every(port => servers.includes(port))) break
  }
  assert.deepEqual(expected.filter(port => !servers.includes(port)), [], `Not reachable on the computer's own address: ${expected.filter(port => !servers.includes(port))}`)
  console.log(`Servers on the computer's own address: ${servers.join(', ')} (loopback ones through caboose-ports)`)

  // The fence: the computer reaches neither the tailnet, nor its companion, nor the LAN.
  const companion = (await docker(['inspect', '-f', `{{with index .NetworkSettings.Networks "${network}"}}{{.IPAddress}}{{end}}`, `${computer}-net`])).trim()
  const peer = process.env.CABOOSE_CHECK_PEER ?? '100.100.100.100'
  const probe = await exec('caboose', `python3 - <<'EOF'
import socket
for host, port in (('${peer}', 22), ('${peer}', 53), ('${companion}', 41641), ('${companion}', 80), ('192.168.1.1', 80)):
    try:
        socket.create_connection((host, port), 3).close()
        print('open', host, port)
    except OSError:
        print('closed', host, port)
EOF`)
  assert.ok(!probe.includes('open '), `The computer reached beyond its fence:\n${probe}`)
  console.log('Fence: the computer reaches neither the tailnet, its companion, nor private ranges.')
  console.log(`From another device on the tailnet: node apps/host/scripts/check-network-client.mjs ${status.name} ${expected.join(',')}`)
  passed = true
  if (args.has('--keep')) console.log(`Kept. Remove with CABOOSE_CHECK_REMOVE=${suffix} and the same command.`)
} finally {
  if (!args.has('--keep') || !passed) await remove().catch(error => console.error('Cleanup failed:', error))
}
