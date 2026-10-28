// Real-host check: launch one GUI, one TUI and one agent without parking the VM.
import { createServer } from 'node:net'
import { spawn } from 'node:child_process'
import { WebSocket } from 'ws'

const base = process.env.CABOOSE_URL ?? 'http://127.0.0.1:7310'
const owner = process.env.CABOOSE_OWNER_TOKEN
if (!owner) throw new Error('Set CABOOSE_OWNER_TOKEN')
const headers = { authorization: `Bearer ${owner}` }
async function request(path, method = 'GET') {
  const response = await fetch(new URL(path, base), { method, headers, signal: AbortSignal.timeout(420_000) })
  if (!response.ok) throw new Error(`${method} ${path}: HTTP ${response.status}: ${await response.text()}`)
  return response.json()
}
const session = await request('/v1/session', 'POST')
const apps = await request('/v1/apps')
const wanted = [
  ['org.xfce.mousepad.desktop', 'Mousepad'],
  ['caboose-btop.desktop', 'btop'],
  ['caboose-opencode.desktop', 'OpenCode'],
]
for (const [id] of wanted) {
  const app = apps.find(x => x.id === id)
  if (!app?.icon?.startsWith('data:image/png;base64,')) throw new Error(`${id}: missing app or PNG icon`)
}
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
async function titles() {
  const child = spawn('xpra', ['info', `tcp://127.0.0.1:${bridge.address().port}/`, '--username=caboose', '--compressors=lz4', '--packet-encoders=rencodeplus'], { env: { ...process.env, XPRA_PASSWORD: session.display.token }, stdio: ['ignore', 'pipe', 'pipe'] })
  let output = ''
  child.stdout.on('data', data => { output += data })
  child.stderr.on('data', data => { output += data })
  const timer = setTimeout(() => child.kill('SIGKILL'), 60_000)
  const code = await new Promise((resolve, reject) => { child.on('error', reject); child.on('close', resolve) }).finally(() => clearTimeout(timer))
  if (code !== 0) throw new Error(`Xpra info failed (${code}): ${output}`)
  return new Map([...output.matchAll(/^windows\.(\d+)\.title=(.*)$/gm)].map(m => [m[1], m[2].replace(/^['"]|['"]$/g, '')]))
}
try {
  const before = await titles()
  for (const [id] of wanted) await request(`/v1/apps/${encodeURIComponent(id)}/launch`, 'POST')
  const deadline = Date.now() + 60_000
  let missing = wanted.map(([, title]) => title)
  while (Date.now() < deadline && missing.length) {
    const after = await titles()
    missing = wanted.map(([, title]) => title).filter(title => ![...after].some(([id, value]) => !before.has(id) && value.includes(title)))
    if (missing.length) await new Promise(resolve => setTimeout(resolve, 1000))
  }
  if (missing.length) throw new Error(`No new Xpra window for: ${missing.join(', ')}; close existing windows and retry`)
  console.log('App icons and new Mousepad, btop and OpenCode windows verified')
} finally {
  await new Promise(resolve => bridge.close(resolve))
}
