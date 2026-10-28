// Real-host check: install and launch PhotoCraft, then require a new window on the owner's display.
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
let catalog = await request('/v1/catalog')
let photo = catalog.apps.find(app => app.id === 'photocraft')
if (!photo) throw new Error('PhotoCraft is absent from the catalog')
if (!photo.installedVersion) {
  await request('/v1/catalog/photocraft/install', 'POST')
  const deadline = Date.now() + 30 * 60_000
  while (Date.now() < deadline) {
    await new Promise(resolve => setTimeout(resolve, 2000))
    catalog = await request('/v1/catalog')
    photo = catalog.apps.find(app => app.id === 'photocraft')
    if (photo?.progress?.phase === 'failed') throw new Error(photo.progress.message ?? 'PhotoCraft installation failed')
    if (photo?.installedVersion && !['queued', 'installing'].includes(photo.progress?.phase)) break
  }
  if (!photo?.installedVersion) throw new Error('PhotoCraft did not install before the deadline')
}
const apps = await request('/v1/apps')
const wanted = [['ai.storyteller.photocraft.desktop', 'PhotoCraft']]
for (const [id] of wanted) {
  const app = apps.find(x => x.id === id)
  if (!app?.icon?.startsWith('data:image/png;base64,')) throw new Error(`${id}: missing app or PNG icon`)
}
await expectNewWindows(base, owner, session, request, wanted)
console.log('PhotoCraft installed, launched and opened a new window')
