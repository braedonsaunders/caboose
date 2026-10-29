// Real-host check: install and launch a catalog app (PhotoCraft unless CABOOSE_CATALOG_APP
// names another), then require a new window with its name on the owner's display.
import { expectNewWindows } from './display-client.mjs'

const base = process.env.CABOOSE_URL ?? 'http://127.0.0.1:7310'
const owner = process.env.CABOOSE_OWNER_TOKEN
const id = process.env.CABOOSE_CATALOG_APP ?? 'photocraft'
if (!owner) throw new Error('Set CABOOSE_OWNER_TOKEN')
const headers = { authorization: `Bearer ${owner}` }
async function request(path, method = 'GET') {
  const response = await fetch(new URL(path, base), { method, headers, signal: AbortSignal.timeout(420_000) })
  if (!response.ok) throw new Error(`${method} ${path}: HTTP ${response.status}: ${await response.text()}`)
  return response.json()
}
const session = await request('/v1/session', 'POST')
let catalog = await request('/v1/catalog')
let app = catalog.apps.find(entry => entry.id === id)
if (!app) throw new Error(`${id} is absent from the catalog`)
if (!app.installedVersion) {
  await request(`/v1/catalog/${encodeURIComponent(id)}/install`, 'POST')
  const deadline = Date.now() + 30 * 60_000
  while (Date.now() < deadline) {
    await new Promise(resolve => setTimeout(resolve, 2000))
    catalog = await request('/v1/catalog')
    app = catalog.apps.find(entry => entry.id === id)
    if (app?.progress?.phase === 'failed') throw new Error(app.progress.message ?? `${app.name} installation failed`)
    if (app?.installedVersion && !['queued', 'installing'].includes(app.progress?.phase)) break
  }
  if (!app?.installedVersion) throw new Error(`${app?.name ?? id} did not install before the deadline`)
}
const apps = await request('/v1/apps')
const wanted = [[app.desktopId, app.name]]
for (const [desktopId] of wanted) {
  const entry = apps.find(x => x.id === desktopId)
  if (!entry?.icon?.startsWith('data:image/png;base64,')) throw new Error(`${desktopId}: missing app or PNG icon`)
}
await expectNewWindows(base, owner, session, request, wanted)
console.log(`${app.name} ${app.installedVersion} installed, launched and opened a new window`)
