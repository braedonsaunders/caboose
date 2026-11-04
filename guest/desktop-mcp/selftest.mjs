// Protocol self-test: needs no X server. node guest/desktop-mcp/selftest.mjs
import { spawn } from 'node:child_process'
import assert from 'node:assert/strict'
const server = spawn(process.execPath, [new URL('./caboose-desktop-mcp.mjs', import.meta.url).pathname], {
  // A display that does not exist, so the accessibility tools reach a11y.py and fail cleanly.
  stdio: ['pipe', 'pipe', 'inherit'], env: { ...process.env, CABOOSE_AGENT_DISPLAY: ':987' },
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
const listed = (await wait(2)).result.tools
const names = listed.map(tool => tool.name)
assert.deepEqual(names, ['look', 'act', 'screenshot'])
for (const tool of listed) {
  assert.equal(tool.inputSchema.type, 'object', `${tool.name} schema`)
  assert.ok(tool.description.length > 20, `${tool.name} description`)
  for (const key of tool.inputSchema.required ?? []) assert.ok(key in tool.inputSchema.properties, `${tool.name} requires a declared ${key}`)
}
// Every turn carries these definitions: they stay small.
assert.ok(JSON.stringify(listed).length < 2000, `tool definitions are ${JSON.stringify(listed).length} characters`)
let next = 100
async function call(name, args) {
  const id = next++
  send({ jsonrpc: '2.0', id, method: 'tools/call', params: { name, arguments: args } })
  return (await wait(id, 20000)).result
}
// Arguments are checked before any helper runs.
for (const [name, args, pattern] of [
  ['look', { find: '   ' }, /find must be a non-empty string/],
  ['act', {}, /steps must hold 1–30 steps/],
  ['act', { steps: [] }, /steps must hold 1–30 steps/],
  ['screenshot', { window: 'x' }, /window must be a window id/],
]) {
  const result = await call(name, args)
  assert.equal(result.isError, true, `${name} ${JSON.stringify(args)}`)
  assert.match(result.content[0].text, pattern)
}
// A bad step stops the run and says why, without a crash.
for (const [steps, pattern] of [
  [[{ key: 'rm -rf /' }], /key must look like/],
  [[{ wait: 10 }, { wait: 0 }], /Did 1 of 2; stopped: wait must be 10–5000 ms/],
  [[{ press: 'x'.repeat(501) }], /at most 500/],
  [[{ fly: 1 }], /unknown step/],
  [[{ set: 'e1' }], /stale id|set needs text|seat|display/],
]) {
  const result = await call('act', { steps, observe: false })
  assert.match(result.content[0].text, pattern)
}
// Without that display, a11y.py answers an error, which comes back as a tool error, not a crash.
const look = await call('look', {})
assert.equal(look.isError, true)
send({ jsonrpc: '2.0', id: 4, method: 'tools/call', params: { name: 'nope', arguments: {} } })
assert.equal((await wait(4)).error.code, -32602)
send({ jsonrpc: '2.0', id: 5, method: 'bogus' })
assert.equal((await wait(5)).error.code, -32601)
server.kill()
console.log('caboose-desktop-mcp protocol self-test passed')
