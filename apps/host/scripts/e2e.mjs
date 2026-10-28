import { createServer } from 'node:net'
import { spawn } from 'node:child_process'
import { WebSocket } from 'ws'

const base = process.env.CABOOSE_URL ?? 'http://127.0.0.1:7310'
const owner = process.env.CABOOSE_OWNER_TOKEN
const headers = { authorization: `Bearer ${owner}` }
async function request(path, method = 'GET') {
  const response = await fetch(new URL(path, base), { method, headers, signal: AbortSignal.timeout(420_000) })
  if (!response.ok) throw new Error(`${method} ${path}: HTTP ${response.status}: ${await response.text()}`)
  return response.json()
}
async function hello(session, seat = 'owner') {
  const bridge = createServer(socket => {
    const target = new URL(session.display.path, base)
    if (seat === 'agent') target.searchParams.set('seat', 'agent')
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
    const child = spawn('xpra', ['info', `tcp://127.0.0.1:${bridge.address().port}/`, '--username=caboose', '--compressors=lz4', '--packet-encoders=rencodeplus'], { env: { ...process.env, XPRA_PASSWORD: session.display.token }, stdio: ['ignore', 'pipe', 'pipe'] })
    let output = ''
    child.stdout.on('data', data => { output += data })
    child.stderr.on('data', data => { output += data })
    const timer = setTimeout(() => child.kill('SIGKILL'), 60_000)
    const code = await new Promise((resolve, reject) => { child.on('error', reject); child.on('close', resolve) }).finally(() => clearTimeout(timer))
    if (code !== 0) throw new Error(`Xpra authenticated info failed (${code}): ${output}`)
    console.log(`Xpra authenticated hello and info succeeded for ${seat} seat`)
  } finally { await new Promise(resolve => bridge.close(resolve)) }
}
let started = performance.now()
const first = await request('/v1/session', 'POST')
console.log(`First wake (cold only without a snapshot): ${((performance.now() - started) / 1000).toFixed(2)} s`)
await hello(first)
await hello(first, 'agent')
const apps = await request('/v1/apps')
if (!Array.isArray(apps) || apps.length === 0 || apps.some(app => !app.icon?.startsWith('data:image/png;base64,'))) {
  throw new Error('App list is empty or contains an app without a PNG icon')
}
for (const pattern of [/chromium/i, /firefox/i, /code/i, /terminal/i, /thunar/i, /mousepad/i, /libreoffice/i]) {
  if (!apps.some(app => pattern.test(app.name) || pattern.test(app.id))) throw new Error(`Missing app: ${pattern}`)
}
console.log(`App list contains ${apps.length} entries with PNG icons, including the requested desktop applications`)
const terminal = apps.find(app => /xfce4-terminal/i.test(app.id))
if (!terminal) throw new Error('Xfce terminal desktop entry is missing')
const launched = await request(`/v1/apps/${encodeURIComponent(terminal.id)}/launch`, 'POST')
if (!launched.launched) throw new Error('Terminal launch was not confirmed')
console.log('Terminal launch request succeeded')

started = performance.now()
await request('/v1/session/park', 'POST')
console.log(`Park: ${((performance.now() - started) / 1000).toFixed(2)} s`)
started = performance.now()
const second = await request('/v1/session', 'POST')
console.log(`Warm resume: ${((performance.now() - started) / 1000).toFixed(2)} s`)
await hello(second)
const health = await request('/v1/health')
if (health.desk?.lastError) throw new Error(`Desk host reported: ${health.desk.lastError}`)
console.log('Resume succeeded without a reported desk-host error')
await request('/v1/session/park', 'POST')
