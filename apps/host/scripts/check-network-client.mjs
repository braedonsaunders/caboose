#!/usr/bin/env node
// The other half of check-network.mts, run from another device on the tailnet (a laptop
// standing in for the phone): reaches the computer's servers by its MagicDNS name exactly as
// any client would, with no Caboose in the path, and checks Caboose's own services are not
// there. No dependencies.
//
//   node apps/host/scripts/check-network-client.mjs <name> <ports, e.g. 8000,8001,5173,5432>
import assert from 'node:assert/strict'
import { lookup } from 'node:dns/promises'
import { request } from 'node:http'
import { connect } from 'node:net'

const [name, list = '8000,8001'] = process.argv.slice(2)
if (!name) throw new Error('Usage: check-network-client.mjs <name> <ports>')
const ports = list.split(',').map(Number)

function get(port, path, headers = {}) {
  return new Promise((resolve, reject) => {
    const started = performance.now()
    const req = request({ host: name, port, path, headers, family: 4, timeout: 15_000 }, response => {
      const chunks = []
      response.on('data', chunk => chunks.push(chunk))
      response.on('end', () => resolve({ status: response.statusCode, headers: response.headers, body: Buffer.concat(chunks).toString(), ms: Math.round(performance.now() - started) }))
    })
    req.on('upgrade', response => { resolve({ status: response.statusCode, headers: response.headers, body: '', ms: Math.round(performance.now() - started) }); response.socket?.destroy?.(); req.destroy() })
    req.on('timeout', () => req.destroy(new Error('timed out')))
    req.on('error', reject)
    req.end()
  })
}

/** Bytes to a TCP port, and the first bytes back. */
function exchange(host, port, data, family = 4) {
  return new Promise((resolve, reject) => {
    const socket = connect({ host, port, family, timeout: 10_000 }, () => socket.write(data))
    socket.once('data', reply => { socket.destroy(); resolve(reply) })
    socket.on('timeout', () => { socket.destroy(); reject(new Error('timed out')) })
    socket.on('error', reject)
  })
}

const addresses = await lookup(name, { all: true })
console.log(`${name} → ${addresses.map(address => address.address).join(', ')}`)
for (const port of ports.filter(port => [8000, 8001].includes(port))) {
  const page = await get(port, '/')
  assert.equal(page.status, 200, `${port}: HTTP ${page.status}`)
  assert.match(page.body, /Hello from the computer/)
  console.log(`http://${name}:${port}/ → 200 in ${page.ms} ms${port === 8000 ? ' (bound to 127.0.0.1 in the computer)' : ''}`)
}
if (ports.includes(5173)) {
  // Vite answers 403 to any Host but localhost; caboose-ports makes the request look local.
  const page = await get(5173, '/')
  assert.equal(page.status, 200, `Vite: HTTP ${page.status} ${page.body.slice(0, 200)}`)
  assert.match(page.body, /\/@vite\/client/)
  const client = await get(5173, '/@vite/client')
  assert.equal(client.status, 200)
  const hmr = await get(5173, '/', { connection: 'Upgrade', upgrade: 'websocket', origin: `http://${name}:5173`, 'sec-websocket-version': '13', 'sec-websocket-key': Buffer.from('caboose-check-key').toString('base64'), 'sec-websocket-protocol': 'vite-hmr' })
  assert.equal(hmr.status, 101, `HMR: HTTP ${hmr.status}`)
  console.log(`Vite on ${name}:5173 → page ${page.ms} ms, /@vite/client 200, HMR WebSocket 101`)
}
if (ports.includes(5432)) {
  // SSLRequest, then a protocol 3.0 startup for postgres: the server asks for a password.
  assert.equal((await exchange(name, 5432, Buffer.from([0, 0, 0, 8, 0x04, 0xd2, 0x16, 0x2f]))).toString(), 'N')
  const parameters = Buffer.from('user\0postgres\0database\0postgres\0\0')
  const startup = Buffer.alloc(8 + parameters.length)
  startup.writeInt32BE(startup.length, 0); startup.writeInt32BE(196608, 4); parameters.copy(startup, 8)
  const reply = await exchange(name, 5432, startup)
  assert.equal(String.fromCharCode(reply[0]), 'R', `PostgreSQL answered ${reply.subarray(0, 16).toString('hex')}`)
  console.log(`PostgreSQL on ${name}:5432 → authentication request ${reply.readInt32BE(5)} (bound to localhost in the computer)`)
}
for (const port of [14600, 14700, 14701]) {
  await assert.rejects(exchange(name, port, Buffer.from('GET / HTTP/1.0\r\n\r\n')), `Caboose's port ${port} is reachable on the tailnet`)
}
console.log('Caboose ports 14600, 14700 and 14701 are not reachable.')
const v6 = addresses.find(address => address.family === 6)
if (v6) {
  const started = performance.now()
  await assert.rejects(exchange(v6.address, ports[0], Buffer.from('x'), 6))
  const ms = Math.round(performance.now() - started)
  assert.ok(ms < 2000, `IPv6 took ${ms} ms to refuse`)
  console.log(`IPv6 ${v6.address} refuses at once (${ms} ms), so clients fall back to IPv4.`)
}
console.log('Network machine check passed.')
