import { peekSession } from './display-client.mjs'

const base = process.env.CABOOSE_URL ?? 'http://127.0.0.1:7310'
const owner = process.env.CABOOSE_OWNER_TOKEN
const headers = { authorization: `Bearer ${owner}` }
async function request(path, method = 'GET') {
  const response = await fetch(new URL(path, base), { method, headers, signal: AbortSignal.timeout(420_000) })
  if (!response.ok) throw new Error(`${method} ${path}: HTTP ${response.status}: ${await response.text()}`)
  return response.json()
}
async function hello(session, seat = 'owner') {
  const { features, encoders } = await peekSession(base, owner, session, { seat, ms: 500 })
  if (!encoders.length) throw new Error(`The ${seat} display offered no encoder this client decodes`)
  console.log(`Authenticated hello succeeded for the ${seat} display (${encoders.join(', ')}; ${features.join(', ')})`)
}
// A wake checks the guest components and refuses a park while that runs; wait it out.
async function settled() {
  for (let deadline = Date.now() + 300_000; Date.now() < deadline; await new Promise(resolve => setTimeout(resolve, 2000))) {
    const { upgrade } = await request('/v1/computer')
    if (upgrade?.state !== 'checking' && upgrade?.state !== 'updating') return
  }
  throw new Error('The guest components did not finish updating within 5 minutes')
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

await settled()
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
await settled()
await request('/v1/session/park', 'POST')
