// Driven by ../check-agent-shell.sh, which starts the container named in CABOOSE_SHELL_CONTAINER.
// The guest commands go through `docker exec -u root`, exactly as the container driver runs
// them, and the runner in the container drives a stand-in ACP agent (guest/agentd/test).
import assert from 'node:assert/strict'
import { execFile } from 'node:child_process'
import { createHash } from 'node:crypto'
import { AgentCatalog } from '../../src/agent-catalog.js'
import { AgentTasks, type AgentEvent, type AgentGuest, type AgentResolver, type AgentTask } from '../../src/agents.js'
import { openUrl, saveDownload } from '../../src/files.js'
import { HomeOwnership } from '../../src/home.js'
import { AgentRegistry } from '../../src/registry.js'
import { SettingsStore, settingsLimits } from '../../src/settings.js'

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

/** Three stand-ins: one that can reload its sessions, one that cannot, one that needs a sign-in. */
const PACKAGE = '@caboose/stand-in-agent@1.0.0'
const stand = (id: string, name: string, env: Record<string, string>) => ({
  id, name, version: '1.0.0', description: 'A stand-in ACP agent', license: 'AGPL-3.0', distribution: { npx: { package: PACKAGE, env } },
})
const registryJson = { version: '1.0.0', agents: [
  stand('stand-in', 'Stand-in', { STAND_IN_CAPS: 'load,image' }),
  stand('stand-in-plain', 'Plain stand-in', {}),
  stand('stand-in-auth', 'Signed stand-in', { STAND_IN_AUTH: '1', STAND_IN_STATE: '/home/caboose/.stand-in' }),
] }
const registry = new AgentRegistry({ fetch: (async () => new Response(JSON.stringify(registryJson))) as unknown as typeof fetch })
const settings = new SettingsStore({ name: 'Check', memoryMb: 2048, vcpus: 2, idleMs: 600_000, defaultAgent: 'stand-in' }, settingsLimits(), { load: async () => undefined, save: async () => {} })
// Checked on every operation here (interval 0), as the host does once per five minutes.
const home = new HomeOwnership(0)
const catalog = new AgentCatalog(registry, () => guest, settings, home)
const events: AgentEvent[] = []
const host = (idleMs = 600_000, resolver: AgentResolver = catalog) => new AgentTasks(() => guest, event => events.push(event), () => () => {}, { resolver, home, pollMs: 300, ensureSeat: async () => {}, idleMs })
const find = (list: AgentTasks, id: string): AgentTask => list.list().find(task => task.id === id)!
async function until(what: string, done: () => boolean | Promise<boolean>, seconds = 30): Promise<void> {
  for (let i = 0; i < seconds * 10; i++) {
    if (await done()) return
    await new Promise(resolve => setTimeout(resolve, 100))
  }
  throw new Error(`Timed out waiting for ${what}`)
}
const outputs = (id: string) => events.filter(event => event.type === 'agent.task.output' && event.id === id).map(event => (event as { text: string }).text)
const transcript = async (id: string) => (await sh(`cat /home/caboose/Agents/${id}/transcript.jsonl`)).split('\n').map(line => JSON.parse(line) as Record<string, unknown>)
const finished = (list: AgentTasks, id: string) => until(`task ${id} to finish`, () => find(list, id).status !== 'running')

// Something ran as root with HOME=/home/caboose and left root-owned caches; the next task
// gives them back to caboose before npm (npx) runs as caboose.
await sh('install -d /home/caboose/.npm/_cacache /home/caboose/.cache/stray && touch /home/caboose/.npm/_cacache/root-file && chown -R root:root /home/caboose/.npm /home/caboose/.cache/stray')
assert.notEqual(await sh('find /home/caboose -xdev ! -user caboose | wc -l'), '0')

// The default agent, with attachments: one over a megabyte, a picture, and two that collide by name.
const tasks = host()
const big = Buffer.alloc(1_500_000)
for (let i = 0; i < big.length; i++) big[i] = (i * 7) % 256
const task = await tasks.start({ prompt: 'First prompt', attachments: [
  { name: '../evil name.bin', type: 'application/octet-stream', data: big.toString('base64') },
  { name: 'evil name.bin', type: 'application/octet-stream', data: Buffer.from('x').toString('base64') },
  { name: 'dot.png', type: 'image/png', data: Buffer.from([0x89, 0x50, 0x4e, 0x47]).toString('base64') },
] })
const dir = `/home/caboose/Agents/${task.id}`
assert.equal(await sh(`sha256sum "${dir}/attachments/evil name.bin" | cut -c1-64`), createHash('sha256').update(big).digest('hex'))
assert.equal(await sh(`stat -c %U "${dir}/attachments/evil name (2).bin" "${dir}/task.json"`), 'caboose\ncaboose')
await finished(tasks, task.id)
assert.equal(find(tasks, task.id).status, 'succeeded', find(tasks, task.id).summary)
assert.equal(find(tasks, task.id).summary, 'done: First prompt')
assert.equal(find(tasks, task.id).agentName, 'Stand-in')
assert.ok(outputs(task.id).includes('turns in session: 1; mcp: caboose-desktop; blocks: text,link:evil name.bin,link:evil name (2).bin,image:image/png; recap: no; display: :101'), outputs(task.id).join('\n'))
assert.equal(await sh('find /home/caboose -xdev \\( ! -user caboose -o ! -group caboose \\) | wc -l'), '0')
console.log('Root-owned leftovers in the home given back to caboose.')
console.log('Start, attachments as ACP content, the desktop MCP server and streaming passed.')

// Reply at once: the runner is still waiting, so the same session continues.
await tasks.reply(task.id, { prompt: 'Second prompt' })
await finished(tasks, task.id)
assert.equal(find(tasks, task.id).summary, 'done: Second prompt')
assert.ok(outputs(task.id).some(text => text.startsWith('turns in session: 2;')))
assert.equal((await transcript(task.id)).filter(event => event.type === 'session').length, 1)
console.log('Reply continued the same session.')

// Ask before acting: the runner's request surfaces in the poll and the chosen option reaches the agent.
const ask = await tasks.start({ prompt: 'ask', approvals: 'ask' })
await until('an approval request', () => Boolean(find(tasks, ask.id).pendingApproval))
const pending = find(tasks, ask.id).pendingApproval!
assert.equal(pending.summary, 'Delete build: rm -rf build')
assert.deepEqual(pending.options?.map(option => option.id), ['yes', 'always', 'no'])
assert.equal(await tasks.resolveApproval(ask.id, pending.id, { allow: true, optionId: 'always' }), true)
assert.equal(await tasks.resolveApproval(ask.id, pending.id, { allow: true }), false)
await finished(tasks, ask.id)
assert.ok(outputs(ask.id).includes('permission: always'))
console.log('Approval round trip passed.')

// Cancel: session/cancel reaches the agent, and the task can be continued afterwards.
const slow = await tasks.start({ prompt: 'slow' })
await until('the slow turn to begin', async () => (await sh(`grep -c '"type":"session"' /home/caboose/Agents/${slow.id}/transcript.jsonl || true`)) === '1')
assert.equal(await tasks.cancel(slow.id), true)
await until('the cancelled turn to end', async () => (await sh(`grep -c '"stopReason":"cancelled"' /home/caboose/Agents/${slow.id}/transcript.jsonl || true`)) === '1')
await tasks.reply(slow.id, { prompt: 'after the cancel' })
await finished(tasks, slow.id)
assert.equal(find(tasks, slow.id).summary, 'done: after the cancel')
console.log('Cancel passed.')
tasks.pause()

// A runner that has gone idle exits; the reply starts a new one, which reloads the session
// (session/load) or, for an agent that cannot, starts a new one with a recap.
const brief = host(1000)
const loads = await brief.start({ prompt: 'remember this' })
const plain = await brief.start({ prompt: 'remember that', agent: 'stand-in-plain' })
await finished(brief, loads.id)
await finished(brief, plain.id)
await until('both runners to exit', async () => (await sh(`cat /home/caboose/Agents/${loads.id}/exit-code /home/caboose/Agents/${plain.id}/exit-code 2>/dev/null | tr -d '\\n'`)) === '00')
await brief.reply(loads.id, { prompt: 'and now' })
await brief.reply(plain.id, { prompt: 'and now' })
await finished(brief, loads.id)
await finished(brief, plain.id)
assert.deepEqual((await transcript(loads.id)).filter(event => event.type === 'session').map(event => event.continuity), ['new', 'load'])
assert.ok(outputs(loads.id).some(text => text.startsWith('turns in session: 2;')))
assert.deepEqual((await transcript(plain.id)).filter(event => event.type === 'session').map(event => event.continuity), ['new', 'recap'])
assert.match(find(brief, plain.id).summary!, /^Plain stand-in cannot reload conversations/)
brief.pause()
console.log('A new runner reloaded one session and recapped the other.')

// Signed out: the task fails with the agent's sign-in methods; signing in through the
// catalog (ACP authenticate, detached) lets a reply go through.
const signedOut = await tasks.start({ prompt: 'hello', agent: 'stand-in-auth' })
await finished(tasks, signedOut.id)
assert.equal(find(tasks, signedOut.id).summary, 'Sign in to Signed stand-in first.')
assert.deepEqual(find(tasks, signedOut.id).signIn?.map(method => [method.id, method.type]), [['stand-in-login', 'agent'], ['stand-in-terminal', 'terminal']])
const listed = (await catalog.list()).agents.find(agent => agent.id === 'stand-in-auth')!
assert.deepEqual(listed.signIn?.map(method => method.id), ['stand-in-login', 'stand-in-terminal'])
assert.deepEqual(await catalog.signIn('stand-in-auth', { methodId: 'stand-in-login' }), { started: true, method: { id: 'stand-in-login', name: 'Stand-in account', description: 'Sign in through the agent', type: 'agent' } })
await until('the sign-in to finish', async () => (await catalog.list()).agents.find(agent => agent.id === 'stand-in-auth')?.signInStatus?.status === 'succeeded')
await tasks.reply(signedOut.id, { prompt: 'hello again' })
await finished(tasks, signedOut.id)
assert.equal(find(tasks, signedOut.id).summary, 'done: hello again')
tasks.pause()
console.log('Signed-out task, sign-in and retry passed.')

// A new host process rebuilds the list from the guest and can still reply.
const restored = host()
await restored.restore()
assert.equal(find(restored, task.id).turns, 2)
assert.equal(find(restored, task.id).attachments?.length, 3)
assert.equal(find(restored, task.id).agentName, 'Stand-in')
assert.equal(find(restored, ask.id).approvals, 'ask')
assert.equal(find(restored, signedOut.id).status, 'succeeded')
await restored.reply(task.id, { prompt: 'Third prompt' })
await finished(restored, task.id)
assert.equal(find(restored, task.id).summary, 'done: Third prompt')
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
