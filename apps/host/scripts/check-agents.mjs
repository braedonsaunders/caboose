#!/usr/bin/env node
// Run against a real host. It wakes the computer, saves a file to ~/Downloads, lists the ACP
// registry's agents, and runs a short real task with an attachment, approvals asked through
// the API, and a reply, using the agent given with --agent (default: the computer's default
// agent). The agent must already be signed in; --install installs it first. --open also
// opens https://example.com on the owner's display. It starts real agent runs on the
// owner's account.
import assert from 'node:assert/strict'

const base = (process.env.CABOOSE_URL ?? 'http://127.0.0.1:7310').replace(/\/$/, '')
const token = process.env.CABOOSE_OWNER_TOKEN
if (!token) throw new Error('Set CABOOSE_OWNER_TOKEN in the environment')
const argv = process.argv.slice(2)
const options = { install: false, open: false, agent: undefined }
for (let i = 0; i < argv.length; i++) {
  if (argv[i] === '--install') options.install = true
  else if (argv[i] === '--open') options.open = true
  else if (argv[i] === '--agent' && argv[i + 1]) options.agent = argv[++i]
  else throw new Error('Usage: check-agents.mjs [--agent <registry id>] [--install] [--open]')
}

async function call(path, method = 'GET', body) {
  const response = await fetch(base + path, {
    method, signal: AbortSignal.timeout(900_000),
    headers: { Authorization: `Bearer ${token}`, 'Content-Type': 'application/json' },
    ...(body === undefined ? {} : { body: JSON.stringify(body) }),
  })
  return { status: response.status, body: await response.json().catch(() => undefined) }
}
async function request(path, method = 'GET', body) {
  const { status, body: json } = await call(path, method, body)
  assert.equal(status, 200, `${method} ${path}: HTTP ${status} ${JSON.stringify(json)}`)
  return json
}
const b64 = text => Buffer.from(text).toString('base64')
const task = async id => (await request('/v1/agent/tasks')).find(entry => entry.id === id)

/** Waits for the task to finish, approving every request it makes on the way. */
async function finish(id) {
  let approvals = 0
  for (const deadline = Date.now() + 600_000; Date.now() < deadline;) {
    const current = await task(id)
    if (!['running', 'paused'].includes(current.status)) return { task: current, approvals }
    if (current.pendingApproval) {
      console.log(`Approving: ${current.pendingApproval.summary}`)
      const { resolved } = await request(`/v1/agent/tasks/${id}/approvals/${current.pendingApproval.id}`, 'POST', { allow: true })
      assert.equal(resolved, true)
      approvals++
    }
    await new Promise(resolve => setTimeout(resolve, 1000))
  }
  throw new Error(`Task ${id} did not finish within 10 minutes`)
}

assert.equal((await request('/v1/session', 'POST')).state, 'running')

const saved = await request('/v1/files', 'POST', { name: '../caboose-check.txt', data: b64('saved by check-agents\n') })
assert.match(saved.path, /^\/home\/caboose\/Downloads\/caboose-check( \(\d+\))?\.txt$/)
assert.equal((await call('/v1/open', 'POST', { url: 'file:///etc/passwd' })).status, 400)
if (options.open) assert.deepEqual(await request('/v1/open', 'POST', { url: 'https://example.com/' }), { opened: true })
console.log(`Saved ${saved.path}; link checks passed.`)

const catalog = await request('/v1/agents')
assert.ok(catalog.agents.length > 0, `The registry is empty: ${catalog.registry.error ?? 'no agents'}`)
const agent = options.agent ?? catalog.defaultAgent
assert.ok(agent, 'Pass --agent <registry id> or set a default agent in Settings')
const listing = catalog.agents.find(entry => entry.id === agent)
assert.ok(listing, `${agent} is not in the registry`)
console.log(`${catalog.agents.length} agents in the registry${catalog.registry.error ? ` (${catalog.registry.error})` : ''}; using ${listing.name} ${listing.installed?.version ?? '(not installed)'}.`)
if (options.install) {
  const { agent: installed } = await request(`/v1/agents/${agent}/install`, 'POST')
  assert.equal(installed.installed?.version, listing.version)
  console.log(`Installed ${installed.name} ${installed.installed.version}; sign-in methods: ${(installed.signIn ?? []).map(method => `${method.name} (${method.type})`).join(', ') || 'none'}.`)
}

const { id } = await request('/v1/agent/tasks', 'POST', {
  prompt: 'Read the attached file. Then run the shell command `echo caboose-approved`. Finally reply with only the word that was in the file.',
  agent, approvals: 'ask',
  attachments: [{ name: 'word.txt', type: 'text/plain', data: b64('pelican\n') }],
})
const started = await task(id)
assert.equal(started.approvals, 'ask')
assert.deepEqual(started.attachments, [`/home/caboose/Agents/${id}/attachments/word.txt`])
const first = await finish(id)
if (first.task.signIn) throw new Error(`${first.task.summary} Sign in with POST /v1/agents/${agent}/sign-in using one of: ${first.task.signIn.map(method => method.id).join(', ')}`)
assert.equal(first.task.status, 'succeeded', first.task.summary)
assert.match(first.task.summary, /pelican/i)
console.log(`${listing.name} asked ${first.approvals} time(s) and read the attachment.`)

const replied = await request(`/v1/agent/tasks/${id}/reply`, 'POST', { prompt: 'Now reply with only that same word in capital letters.' })
assert.equal(replied.task.turns, 2)
const second = await finish(id)
assert.equal(second.task.status, 'succeeded', second.task.summary)
assert.match(second.task.summary, /PELICAN/)
console.log('The reply continued the conversation.')
console.log('Agent checks passed.')
