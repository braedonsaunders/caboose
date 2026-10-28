// Driven by ../check-agent-shell.sh, which starts the container named in CABOOSE_SHELL_CONTAINER.
// The guest commands go through `docker exec -u root`, exactly as the container driver runs them.
import assert from 'node:assert/strict'
import { execFile } from 'node:child_process'
import { createHash } from 'node:crypto'
import { AgentTasks, type AgentEvent, type AgentGuest, type AgentTask } from '../../src/agents.js'
import { openUrl, saveDownload } from '../../src/files.js'

const name = process.env.CABOOSE_SHELL_CONTAINER
if (!name) throw new Error('Run through scripts/check-agent-shell.sh')
let commands = 0
const guest: AgentGuest = {
  run: (command, args, timeoutMs = 30_000) => new Promise((resolve, reject) => {
    commands++
    execFile('docker', ['exec', '-u', 'root', name, command, ...args], { timeout: timeoutMs, maxBuffer: 64 * 1024 * 1024 }, (error, stdout, stderr) => {
      if (error) reject(new Error(`${error.message}\n${stderr}`))
      else resolve(stdout)
    })
  }),
}
const sh = async (script: string) => (await guest.run('/bin/sh', ['-c', script])).trim()
const events: AgentEvent[] = []
const host = () => new AgentTasks(() => guest, event => events.push(event), () => () => {}, 300, async () => {})
const tasks = host()
const find = (list: AgentTasks, id: string): AgentTask => list.list().find(task => task.id === id)!
async function until(what: string, done: () => boolean): Promise<void> {
  for (let i = 0; i < 150; i++) {
    if (done()) return
    await new Promise(resolve => setTimeout(resolve, 100))
  }
  throw new Error(`Timed out waiting for ${what}`)
}

// Claude, pre-approved tools, with attachments: one over a megabyte and two that collide by name.
const big = Buffer.alloc(1_500_000)
for (let i = 0; i < big.length; i++) big[i] = (i * 7) % 256
const task = await tasks.start({ prompt: 'First prompt', attachments: [
  { name: '../evil name.bin', type: 'application/octet-stream', data: big.toString('base64') },
  { name: 'evil name.bin', type: 'application/octet-stream', data: Buffer.from('x').toString('base64') },
] })
const dir = `/home/caboose/Agents/${task.id}`
assert.equal(await sh(`sha256sum "${dir}/attachments/evil name.bin" | cut -c1-64`), createHash('sha256').update(big).digest('hex'))
assert.equal(await sh(`stat -c %U "${dir}/attachments/evil name (2).bin"`), 'caboose')
await until('the first turn', () => find(tasks, task.id).status !== 'running')
assert.equal(find(tasks, task.id).status, 'succeeded')
assert.match(find(tasks, task.id).summary!, /done: First prompt as caboose in :101/)
assert.ok(events.some(event => event.type === 'agent.task.output' && event.text === 'heard: First prompt (lines: 4)'), 'attachments are listed in the prompt')
await new Promise(resolve => setTimeout(resolve, 300))
assert.equal(await sh(`cat ${dir}/session`), 'c237ef1f-3019-47c0-b325-b54d7cb4781d')
console.log('Start, attachments, streaming and session capture passed.')

// Reply at once, while the first turn's process may still be exiting.
await tasks.reply(task.id, { prompt: 'Second prompt' })
await until('the second turn', () => find(tasks, task.id).status !== 'running')
assert.match(find(tasks, task.id).summary!, /done: Second prompt/)
assert.equal(find(tasks, task.id).turns, 2)
assert.equal(await sh(`grep -c '"type":"result"' ${dir}/transcript.jsonl`), '2')
console.log('Reply appended to the same transcript.')

// Ask before acting: the request surfaces in the poll and the decision reaches the agent.
const ask = await tasks.start({ prompt: 'Ask first', approvals: 'ask' })
await until('an approval request', () => Boolean(find(tasks, ask.id).pendingApproval))
const pending = find(tasks, ask.id).pendingApproval!
assert.equal(pending.summary, 'Bash: rm -rf build')
assert.equal(await tasks.resolveApproval(ask.id, pending.id, { allow: true }), true)
assert.equal(await tasks.resolveApproval(ask.id, pending.id, { allow: true }), false)
await until('the approved turn', () => find(tasks, ask.id).status !== 'running')
assert.ok(events.some(event => event.type === 'agent.task.output' && event.text === 'decision allow:true'))
console.log('Approval round trip passed.')

// Codex: a thread is resumed with its id and the sandbox override.
const codex = await tasks.start({ prompt: 'Codex one', agent: 'codex' })
await until('the Codex turn', () => find(tasks, codex.id).status !== 'running')
await tasks.reply(codex.id, { prompt: 'Codex two' })
await until('the resumed Codex turn', () => find(tasks, codex.id).status !== 'running')
assert.equal(find(tasks, codex.id).summary, 'codex heard Codex two')
assert.equal(await sh(`sort -u /home/caboose/Agents/${codex.id}/codex-config.log`), 'sandbox_mode=workspace-write')
console.log('Codex resume passed.')
tasks.pause()

// A new host process rebuilds the list from the guest and can still reply.
const restored = host()
await restored.restore()
assert.equal(find(restored, task.id).turns, 2)
assert.equal(find(restored, task.id).attachments?.length, 2)
assert.equal(find(restored, ask.id).approvals, 'ask')
await restored.reply(task.id, { prompt: 'Third prompt' })
await until('the turn after a host restart', () => find(restored, task.id).status !== 'running')
assert.match(find(restored, task.id).summary!, /done: Third prompt/)
restored.pause()
console.log('Restore and reply after a host restart passed.')

// Downloads: chunked writes, sanitised and de-duplicated names, owned by caboose.
const upload = Buffer.alloc(900_000, 65)
assert.deepEqual(await saveDownload(guest, { name: 'report.pdf', data: upload.toString('base64') }), { path: '/home/caboose/Downloads/report.pdf' })
assert.deepEqual(await saveDownload(guest, { name: '../report.pdf', data: 'aGk=' }), { path: '/home/caboose/Downloads/report (2).pdf' })
assert.deepEqual(await saveDownload(guest, { name: '.bashrc', data: 'aGk=' }), { path: '/home/caboose/Downloads/bashrc' })
assert.equal(await sh('stat -c "%U %s" /home/caboose/Downloads/report.pdf'), 'caboose 900000')
assert.equal(await sh('ls -A /home/caboose/Downloads | grep -c part || true'), '0')
// The slim image has neither xdg-open nor gio, so opening must fail loudly rather than pretend.
await assert.rejects(openUrl(guest, { url: 'https://example.com/' }), /no xdg-open or gio/)
console.log(`Downloads passed. Agent and file guest scripts passed (${commands} guest commands).`)
