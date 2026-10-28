// Real-host check: launch one GUI, one TUI and one agent without parking the VM.
import { expectNewWindows } from './display-client.mjs'

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
await expectNewWindows(base, owner, session, request, wanted)
console.log('App icons and new Mousepad, btop and OpenCode windows verified')
