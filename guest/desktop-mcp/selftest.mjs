// Protocol self-test: needs no X server. node guest/desktop-mcp/selftest.mjs
import { spawn } from 'node:child_process'
import assert from 'node:assert/strict'
import { mkdtemp, readdir, readFile, rm, writeFile } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
const taskDir = await mkdtemp(join(tmpdir(), 'caboose-mcp-'))
const server = spawn(process.execPath, [new URL('./caboose-desktop-mcp.mjs', import.meta.url).pathname], {
  stdio: ['pipe', 'pipe', 'inherit'], env: { ...process.env, CABOOSE_TASK_DIR: taskDir, CABOOSE_APPROVAL_POLL_MS: '20' },
})
const replies = []
let buffer = ''
server.stdout.on('data', chunk => {
  buffer += chunk
  let index
  while ((index = buffer.indexOf('\n')) >= 0) { replies.push(JSON.parse(buffer.slice(0, index))); buffer = buffer.slice(index + 1) }
})
const send = message => server.stdin.write(JSON.stringify(message) + '\n')
const wait = (id, timeoutMs = 5000) => new Promise((resolve, reject) => {
  const started = Date.now()
  const timer = setInterval(() => {
    const found = replies.find(r => r.id === id)
    if (found) { clearInterval(timer); resolve(found) } else if (Date.now() - started > timeoutMs) { clearInterval(timer); reject(new Error(`no reply to ${id}`)) }
  }, 10)
})
send({ jsonrpc: '2.0', id: 1, method: 'initialize', params: { protocolVersion: '2025-06-18', capabilities: {}, clientInfo: { name: 'selftest', version: '0' } } })
assert.equal((await wait(1)).result.serverInfo.name, 'caboose-desktop')
send({ jsonrpc: '2.0', method: 'notifications/initialized' })
send({ jsonrpc: '2.0', id: 2, method: 'tools/list' })
const names = (await wait(2)).result.tools.map(tool => tool.name)
assert.deepEqual(names, ['screenshot', 'list_windows', 'focus', 'click', 'drag', 'type', 'key', 'scroll', 'launch', 'approve'])
send({ jsonrpc: '2.0', id: 3, method: 'tools/call', params: { name: 'key', arguments: { combo: 'rm -rf /' } } })
assert.equal((await wait(3)).result.isError, true)
send({ jsonrpc: '2.0', id: 4, method: 'tools/call', params: { name: 'nope', arguments: {} } })
assert.equal((await wait(4)).error.code, -32602)
send({ jsonrpc: '2.0', id: 5, method: 'bogus' })
assert.equal((await wait(5)).error.code, -32601)
// approve: a request file appears in $CABOOSE_TASK_DIR/approvals, and the answer follows the decision file.
async function pendingRequest() {
  for (let i = 0; i < 250; i++) {
    const names = await readdir(join(taskDir, 'approvals')).catch(() => [])
    const request = names.find(name => name.endsWith('.json') && !names.includes(name.replace(/\.json$/, '.decision')))
    if (request) return request.replace(/\.json$/, '')
    await new Promise(resolve => setTimeout(resolve, 20))
  }
  throw new Error('no approval request written')
}
const command = 'echo ' + 'x'.repeat(5000)
send({ jsonrpc: '2.0', id: 6, method: 'tools/call', params: { name: 'approve', arguments: { tool_name: 'Bash', input: { command }, tool_use_id: 'toolu_1' } } })
const allowId = await pendingRequest()
assert.match(allowId, /^[0-9a-f-]{36}$/)
const request = JSON.parse(await readFile(join(taskDir, 'approvals', `${allowId}.json`), 'utf8'))
assert.equal(request.tool, 'Bash')
assert.ok(request.input.command.length < command.length, 'long inputs are cut for display')
await writeFile(join(taskDir, 'approvals', `${allowId}.decision`), JSON.stringify({ allow: true }))
assert.deepEqual(JSON.parse((await wait(6)).result.content[0].text), { behavior: 'allow', updatedInput: { command } })
send({ jsonrpc: '2.0', id: 7, method: 'tools/call', params: { name: 'approve', arguments: { tool_name: 'Write', input: { file_path: '/etc/passwd' } } } })
const denyId = await pendingRequest()
await writeFile(join(taskDir, 'approvals', `${denyId}.decision`), JSON.stringify({ allow: false, message: 'Not that file.' }))
assert.deepEqual(JSON.parse((await wait(7)).result.content[0].text), { behavior: 'deny', message: 'Not that file.' })
server.kill()
await rm(taskDir, { recursive: true, force: true })
console.log('caboose-desktop-mcp protocol self-test passed')
