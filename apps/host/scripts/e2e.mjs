import { createServer } from 'node:net'
import { spawn } from 'node:child_process'
import { WebSocket } from 'ws'

const base = process.env.CABOOSE_URL ?? 'http://127.0.0.1:7310'
const owner = process.env.CABOOSE_OWNER_TOKEN
const headers = { authorization: `Bearer ${owner}` }
async function request(path, method = 'GET') {
  const response = await fetch(new URL(path, base), { method, headers, signal: AbortSignal.timeout(180_000) })
  if (!response.ok) throw new Error(`${method} ${path}: HTTP ${response.status}: ${await response.text()}`)
  return response.json()
}
async function hello(session) {
  const bridge = createServer(socket => {
    const target = new URL(session.display.path, base)
    target.protocol = target.protocol === 'https:' ? 'wss:' : 'ws:'
    const ws = new WebSocket(target, 'binary', { headers })
    socket.pause()
    ws.on('open', () => socket.resume())
    socket.on('data', chunk => { socket.pause(); ws.send(chunk, error => error ? socket.destroy() : socket.resume()) })
    ws.on('message', (data, binary) => { if (!binary) return socket.destroy(); if (!socket.write(data)) { ws.pause(); socket.once('drain', () => ws.resume()) } })
    ws.on('error', () => socket.destroy())
    ws.on('close', () => socket.destroy())
    socket.on('error', () => ws.terminate())
    socket.on('close', () => ws.terminate())
  })
  await new Promise((resolve, reject) => { bridge.once('error', reject); bridge.listen(0, '127.0.0.1', resolve) })
  try {
    const child = spawn('xpra', ['info', `tcp://127.0.0.1:${bridge.address().port}/`], { env: { ...process.env, XPRA_PASSWORD: session.display.token }, stdio: ['ignore', 'pipe', 'pipe'] })
    let output = ''
    child.stdout.on('data', data => { output += data })
    child.stderr.on('data', data => { output += data })
    const timer = setTimeout(() => child.kill('SIGKILL'), 60_000)
    const code = await new Promise((resolve, reject) => { child.on('error', reject); child.on('close', resolve) }).finally(() => clearTimeout(timer))
    if (code !== 0) throw new Error(`Xpra authenticated info failed (${code}): ${output}`)
    console.log('Xpra authenticated hello and info succeeded')
  } finally { await new Promise(resolve => bridge.close(resolve)) }
}
const first = await request('/v1/session', 'POST')
await hello(first)
await request('/v1/session/park', 'POST')
console.log('Park succeeded')
const second = await request('/v1/session', 'POST')
await hello(second)
const health = await request('/v1/health')
if (health.desk?.lastError) throw new Error(`Desk host reported: ${health.desk.lastError}`)
console.log('Resume succeeded without a reported desk-host error')
await request('/v1/session/park', 'POST')
