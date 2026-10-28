// Protocol self-test: needs no X server. node guest/desktop-mcp/selftest.mjs
import { spawn } from 'node:child_process'
import assert from 'node:assert/strict'
const server = spawn(process.execPath, [new URL('./caboose-desktop-mcp.mjs', import.meta.url).pathname], { stdio: ['pipe', 'pipe', 'inherit'] })
const replies = []
let buffer = ''
server.stdout.on('data', chunk => {
  buffer += chunk
  let index
  while ((index = buffer.indexOf('\n')) >= 0) { replies.push(JSON.parse(buffer.slice(0, index))); buffer = buffer.slice(index + 1) }
})
const send = message => server.stdin.write(JSON.stringify(message) + '\n')
const wait = id => new Promise((resolve, reject) => {
  const started = Date.now()
  const timer = setInterval(() => {
    const found = replies.find(r => r.id === id)
    if (found) { clearInterval(timer); resolve(found) } else if (Date.now() - started > 5000) { clearInterval(timer); reject(new Error(`no reply to ${id}`)) }
  }, 10)
})
send({ jsonrpc: '2.0', id: 1, method: 'initialize', params: { protocolVersion: '2025-06-18', capabilities: {}, clientInfo: { name: 'selftest', version: '0' } } })
assert.equal((await wait(1)).result.serverInfo.name, 'caboose-desktop')
send({ jsonrpc: '2.0', method: 'notifications/initialized' })
send({ jsonrpc: '2.0', id: 2, method: 'tools/list' })
const names = (await wait(2)).result.tools.map(tool => tool.name)
assert.deepEqual(names, ['screenshot', 'list_windows', 'focus', 'click', 'drag', 'type', 'key', 'scroll', 'launch'])
send({ jsonrpc: '2.0', id: 3, method: 'tools/call', params: { name: 'key', arguments: { combo: 'rm -rf /' } } })
assert.equal((await wait(3)).result.isError, true)
send({ jsonrpc: '2.0', id: 4, method: 'tools/call', params: { name: 'nope', arguments: {} } })
assert.equal((await wait(4)).error.code, -32602)
send({ jsonrpc: '2.0', id: 5, method: 'bogus' })
assert.equal((await wait(5)).error.code, -32601)
server.kill()
console.log('caboose-desktop-mcp protocol self-test passed')
