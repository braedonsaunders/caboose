#!/usr/bin/env node
// Run against a real host whose computer has Claude Code (and, with --codex, Codex) signed in.
// It wakes the computer, saves a file to ~/Downloads, and runs short real agent tasks:
// an attachment, an approval answered through the API, and a reply. --open also opens
// https://example.com on the owner's display.
import assert from 'node:assert/strict'

const base = (process.env.CABOOSE_URL ?? 'http://127.0.0.1:7310').replace(/\/$/, '')
const token = process.env.CABOOSE_OWNER_TOKEN
if (!token) throw new Error('Set CABOOSE_OWNER_TOKEN in the environment')
const args = process.argv.slice(2)
if (args.some(value => value !== '--codex' && value !== '--open')) throw new Error('Usage: check-agents.mjs [--codex] [--open]')

async function call(path, method = 'GET', body) {
  const response = await fetch(base + path, {
    method, signal: AbortSignal.timeout(300_000),
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
async function finish(id, { approve = false } = {}) {
  let approvals = 0
  for (const deadline = Date.now() + 600_000; Date.now() < deadline;) {
    const current = await task(id)
    if (!['running', 'paused'].includes(current.status)) return { task: current, approvals }
    if (current.pendingApproval) {
      assert.ok(approve, `Unexpected approval request: ${current.pendingApproval.summary}`)
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
if (args.includes('--open')) assert.deepEqual(await request('/v1/open', 'POST', { url: 'https://example.com/' }), { opened: true })
console.log(`Saved ${saved.path}; link checks passed.`)

assert.equal((await call('/v1/agent/tasks', 'POST', { prompt: 'x', agent: 'codex', approvals: 'ask' })).status, 400)
const { id } = await request('/v1/agent/tasks', 'POST', {
  prompt: 'Read the attached file. Then use the Bash tool to run `echo caboose-approved`. Finally reply with only the word that was in the file.',
  agent: 'claude', approvals: 'ask',
  attachments: [{ name: 'word.txt', type: 'text/plain', data: b64('pelican\n') }],
})
const started = await task(id)
assert.equal(started.approvals, 'ask')
assert.deepEqual(started.attachments, [`/home/caboose/Agents/${id}/attachments/word.txt`])
const first = await finish(id, { approve: true })
assert.equal(first.task.status, 'succeeded', first.task.summary)
assert.ok(first.approvals >= 1, 'Claude asked before running Bash')
assert.match(first.task.summary, /pelican/i)
console.log(`Claude asked ${first.approvals} time(s) and read the attachment.`)

const replied = await request(`/v1/agent/tasks/${id}/reply`, 'POST', { prompt: 'Now reply with only that same word in capital letters.' })
assert.equal(replied.task.turns, 2)
const second = await finish(id, { approve: true })
assert.equal(second.task.status, 'succeeded', second.task.summary)
assert.match(second.task.summary, /PELICAN/)
console.log('Claude reply continued the conversation.')

if (args.includes('--codex')) {
  const codex = await request('/v1/agent/tasks', 'POST', { prompt: 'Reply with only the word apple.', agent: 'codex' })
  assert.equal((await finish(codex.id)).task.status, 'succeeded')
  await request(`/v1/agent/tasks/${codex.id}/reply`, 'POST', { prompt: 'Repeat the word you replied with, in capital letters only.' })
  const resumed = await finish(codex.id)
  assert.match(resumed.task.summary, /APPLE/)
  console.log('Codex reply resumed the thread.')
}
console.log('Agent checks passed.')
