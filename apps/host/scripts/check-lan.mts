#!/usr/bin/env -S node --import tsx
// Real-host check of a computer's own address on the home network (docs/network.md): a
// throwaway container computer gets lan0 through the production LanAddress, a DHCP lease,
// its loopback servers on that address and an mDNS name, while lan0's fence keeps Caboose's
// ports closed and stops the computer starting connections on the LAN.
//
//   CABOOSE_CHECK_IMAGE=caboose-computer:<tag> apps/host/node_modules/.bin/tsx apps/host/scripts/check-lan.mts [--interface <ethernet>]
//
// Without --interface it builds a stand-in LAN on the host: a Linux bridge, a DHCP server
// container on it, and a client address for this check, so it runs on any Linux host,
// WSL included. With --interface it uses the real network, whose DHCP server gives the lease;
// then run check-network-client.mjs from a phone-side machine on that network with the name
// it prints, and remove what it made with CABOOSE_CHECK_REMOVE=<suffix>. Needs Docker and
// root or `sudo -n`. It touches only what it creates.
import assert from 'node:assert/strict'
import { randomBytes } from 'node:crypto'
import { createSocket } from 'node:dgram'
import { request } from 'node:http'
import { connect, createServer } from 'node:net'
import { dockerCli } from '../src/container-driver.js'
import { LanAddress } from '../src/lan.js'
import { fenceBridge, privilegedOutput, unfenceBridge } from '../src/network.js'
import { TAILSCALE_IMAGE } from '../src/tailnet.js'

const docker = dockerCli()
const argv = process.argv.slice(2)
const real = argv.includes('--interface') ? argv[argv.indexOf('--interface') + 1] : undefined
const suffix = process.env.CABOOSE_CHECK_REMOVE ?? randomBytes(3).toString('hex')
const computer = `caboose-check-lan-${suffix}`, network = `caboose-checkl-${suffix}`, bridge = `cbchl${suffix}`
const lanBridge = `cblt${suffix}`, serverLink = `cbls${suffix}`, clientLink = `cblc${suffix}`, dhcp = `caboose-check-dhcp-${suffix}`
const image = process.env.CABOOSE_CHECK_IMAGE ?? 'caboose-computer:latest'
const name = `caboose-lan-${suffix}`
const ip = (args: string[]) => privilegedOutput('ip', args)
const helperImage = process.env.CABOOSE_TAILSCALE_IMAGE || TAILSCALE_IMAGE
const lan = new LanAddress({ config: { mode: 'macvlan', interface: real ?? lanBridge, image: helperImage, allowOut: false },
  docker, privileged: privilegedOutput, computer, slot: 32000 + parseInt(suffix.slice(0, 2), 16), hostname: () => name })
const exec = (user: 'root' | 'caboose', script: string, timeoutMs = 60_000) => docker(['exec', '-u', user, computer, '/bin/sh', '-c', script], timeoutMs)

async function remove(): Promise<void> {
  await lan.destroy()
  for (const container of [computer, dhcp]) await docker(['rm', '-f', container], 60_000).catch(() => {})
  await docker(['network', 'rm', network], 30_000).catch(() => {})
  await unfenceBridge(bridge).catch(() => {})
  for (const link of [clientLink, serverLink, lanBridge]) await ip(['link', 'del', link]).catch(() => {})
}
if (process.env.CABOOSE_CHECK_REMOVE) { await remove(); console.log(`Removed ${computer}.`); process.exit(0) }

function get(host: string, port: number, local?: string): Promise<{ status?: number; body: string }> {
  return new Promise((resolve, reject) => {
    const req = request({ host, port, path: '/', localAddress: local, timeout: 5000 }, response => {
      let body = ''
      response.on('data', chunk => { body += chunk })
      response.on('end', () => resolve({ status: response.statusCode, body }))
    })
    req.on('timeout', () => req.destroy(new Error('timed out')))
    req.on('error', reject)
    req.end()
  })
}

function reachable(host: string, port: number, local?: string): Promise<boolean> {
  return new Promise(resolve => {
    const socket = connect({ host, port, localAddress: local, timeout: 3000 }, () => { socket.destroy(); resolve(true) })
    socket.on('timeout', () => { socket.destroy(); resolve(false) })
    socket.on('error', () => resolve(false))
  })
}

/** A one-shot mDNS query for name's A record, from this check's address on the stand-in LAN. */
function resolveMdns(host: string, local: string): Promise<string | undefined> {
  return new Promise(resolve => {
    const socket = createSocket({ type: 'udp4', reuseAddr: true })
    const labels = Buffer.concat([...host.split('.').map(label => Buffer.concat([Buffer.from([label.length]), Buffer.from(label)])), Buffer.from([0])])
    const query = Buffer.concat([Buffer.from([0x12, 0x34, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0]), labels, Buffer.from([0, 1, 0, 1])])
    const timer = setTimeout(() => { socket.close(); resolve(undefined) }, 5000)
    socket.on('message', reply => {
      if (reply.length < 16 || reply.readUInt16BE(6) < 1) return
      clearTimeout(timer); socket.close()
      resolve([...reply.subarray(reply.length - 4)].join('.'))
    })
    socket.bind(0, local, () => {
      socket.setMulticastInterface(local)
      socket.send(query, 5353, '224.0.0.251')
    })
  })
}

let passed = false
try {
  await docker(['image', 'inspect', image], 15_000)
  if (!real) {
    // The stand-in LAN: a bridge, a DHCP server on it, and this check's own address.
    await ip(['link', 'add', lanBridge, 'type', 'bridge'])
    await ip(['link', 'set', lanBridge, 'up'])
    await docker(['run', '-d', '--name', dhcp, '--network', 'none', '--cap-drop', 'ALL', '--cap-add', 'NET_ADMIN', '--cap-add', 'NET_RAW', '--entrypoint', '/bin/sh', helperImage, '-c',
      'while ! ip link show lan >/dev/null 2>&1; do sleep 0.2; done; ip addr add 10.213.0.1/24 dev lan; ip link set lan up; printf "start 10.213.0.100\\nend 10.213.0.150\\ninterface lan\\nlease_file /tmp/leases\\noption subnet 255.255.255.0\\n" > /tmp/udhcpd.conf; touch /tmp/leases; exec udhcpd -f /tmp/udhcpd.conf'], 300_000)
    const pid = (await docker(['inspect', '-f', '{{.State.Pid}}', dhcp])).trim()
    await ip(['link', 'add', 'link', lanBridge, 'name', serverLink, 'type', 'macvlan', 'mode', 'bridge'])
    await ip(['link', 'set', serverLink, 'netns', pid])
    await docker(['exec', dhcp, 'ip', 'link', 'set', serverLink, 'name', 'lan'])
    await ip(['link', 'add', 'link', lanBridge, 'name', clientLink, 'type', 'macvlan', 'mode', 'bridge'])
    await ip(['addr', 'add', '10.213.0.2/24', 'dev', clientLink])
    await ip(['link', 'set', clientLink, 'up'])
  }
  await docker(['network', 'create', '--driver', 'bridge', '-o', `com.docker.network.bridge.name=${bridge}`, network], 30_000)
  await fenceBridge(bridge)
  await docker(['run', '-d', '--name', computer, '--init', '--network', network, '--dns', '1.1.1.1', '--memory', '2g', '--cpus', '2', image], 120_000)
  await docker(['cp', new URL('../../../guest/ports/caboose-ports.py', import.meta.url).pathname, `${computer}:/opt/caboose-ports.py`], 30_000)
  await exec('root', `install -d -m 0755 /run/caboose && echo '{"forward": true, "mdns": "${name}"}' > /run/caboose/ports.json`)
  await docker(['exec', '-d', '-u', 'caboose', computer, 'python3', '/opt/caboose-ports.py'], 15_000)
  await exec('caboose', 'mkdir -p /tmp/site && echo "<title>Hello from the computer</title>" > /tmp/site/index.html && cd /tmp/site && (nohup python3 -m http.server --bind 127.0.0.1 8000 >/dev/null 2>&1 &) && (nohup python3 -m http.server --bind 0.0.0.0 8001 >/dev/null 2>&1 &) && (nohup python3 -m http.server --bind 0.0.0.0 14650 >/dev/null 2>&1 &)')

  const status = await lan.ensure()
  assert.equal(status.state, 'running', `No address on the home network: ${JSON.stringify(status)}`)
  console.log(`lan0 ${status.address} (${status.name}), MAC from the computer`)
  if (real) {
    console.log(`From another device on that network: node apps/host/scripts/check-network-client.mjs ${status.name} 8000,8001`)
    console.log(`Remove with CABOOSE_CHECK_REMOVE=${suffix} and the same command.`)
    passed = true
    process.exit(0)
  }
  const local = '10.213.0.2'
  await new Promise(resolve => setTimeout(resolve, 1500)) // caboose-ports polls twice a second
  for (const port of [8001, 8000]) {
    const page = await get(status.address!, port, local)
    assert.equal(page.status, 200, `${port} on lan0: ${page.status}`)
    assert.match(page.body, /Hello from the computer/)
  }
  console.log('From the LAN: 8001 (0.0.0.0) and 8000 (127.0.0.1, through caboose-ports) answer.')
  assert.equal(await reachable(status.address!, 14650, local), false, 'A Caboose port answered on lan0')
  console.log('Caboose\'s ports are closed on lan0.')
  assert.equal(await resolveMdns(`${name}.local`, local), status.address, 'mDNS did not answer with lan0\'s address')
  console.log(`mDNS: ${name}.local → ${status.address}`)
  // The computer may answer the LAN but not start connections on it.
  const listener = createServer(socket => socket.end()).listen(18555, local)
  try {
    const probe = await exec('caboose', `python3 -c "import socket\ntry:\n    socket.create_connection(('${local}', 18555), 3).close(); print('open')\nexcept OSError: print('closed')"`)
    assert.equal(probe.trim(), 'closed', 'The computer started a connection on the LAN')
  } finally { listener.close() }
  console.log('Fence: the computer starts no connection on the LAN.')
  await docker(['restart', '-t', '1', computer], 60_000)
  const again = await lan.ensure()
  assert.equal(again.address, status.address, 'The computer got another address after a restart')
  console.log(`After a restart: lan0 again, same address ${again.address}.`)
  passed = true
  console.log('Home network check passed.')
} finally {
  if (!real || !passed) await remove().catch(error => console.error('Cleanup failed:', error))
}
