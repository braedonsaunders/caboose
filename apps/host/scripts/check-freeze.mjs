// Run only against a disposable computer with resident pause enabled and no other clients.
const base = (process.env.CABOOSE_URL ?? 'http://127.0.0.1:7310').replace(/\/$/, '')
const token = process.env.CABOOSE_OWNER_TOKEN
if (!token) throw new Error('Set CABOOSE_OWNER_TOKEN')
const timeout = Number(process.env.CABOOSE_CHECK_TIMEOUT_MS ?? 90000)
if (!Number.isSafeInteger(timeout) || timeout < 10000 || timeout > 600000) throw new Error('CABOOSE_CHECK_TIMEOUT_MS must be 10000–600000')
async function request(path, method = 'GET') {
  const response = await fetch(base + path, { method, headers: { authorization: `Bearer ${token}` }, signal: AbortSignal.timeout(15000) })
  const body = await response.json()
  if (!response.ok) throw new Error(`${method} ${path}: ${response.status} ${JSON.stringify(body)}`)
  return body
}
async function waitFor(state) {
  const deadline = Date.now() + timeout
  while (Date.now() < deadline) {
    const status = await request('/v1/computer')
    if (status.state === state) return status
    if (status.state === 'error') throw new Error(status.lastError ?? 'Computer entered error state')
    await new Promise(resolve => setTimeout(resolve, 500))
  }
  throw new Error(`Timed out waiting for ${state}; check backend pause support, terminal sessions and leases`)
}
const first = await request('/v1/session', 'POST')
const sessions = await request('/v1/terminal/sessions')
if (sessions.sessions.length) throw new Error('Close all terminal sessions before this check')
await waitFor('frozen')
const resumed = await request('/v1/session', 'POST')
if (resumed.display.token !== first.display.token) throw new Error('Resident resume unexpectedly changed the display token')
await waitFor('frozen')
await waitFor('parked')
const restored = await request('/v1/session', 'POST')
if (restored.state !== 'running') throw new Error('Snapshot restore did not return a running session')
console.log('Resident freeze, resume, park and snapshot restore passed')
