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
// The accessibility tools come first, so a model reaches for them before a screenshot.
assert.deepEqual(names, ['elements', 'find', 'click_element', 'set_text', 'read_text',
  'screenshot', 'list_windows', 'focus', 'click', 'drag', 'type', 'key', 'scroll', 'launch'])
for (const tool of listed) {
  assert.equal(tool.inputSchema.type, 'object', `${tool.name} schema`)
  assert.ok(tool.description.length > 20, `${tool.name} description`)
  for (const key of tool.inputSchema.required ?? []) assert.ok(key in tool.inputSchema.properties, `${tool.name} requires a declared ${key}`)
}
const schema = name => listed.find(tool => tool.name === name).inputSchema
assert.deepEqual(schema('find').required, ['query'])
assert.deepEqual(schema('click_element').required, ['id'])
assert.deepEqual(schema('set_text').required, ['id', 'text'])
assert.match(listed[0].description, /screenshot/)
// Arguments are checked before the helper runs.
let next = 100
async function call(name, args) {
  const id = next++
  send({ jsonrpc: '2.0', id, method: 'tools/call', params: { name, arguments: args } })
  return (await wait(id, 20000)).result
}
for (const [name, args, pattern] of [
  ['find', {}, /query must be a non-empty string/],
  ['find', { query: '   ' }, /query must be a non-empty string/],
  ['find', { query: 'save', role: 7 }, /role must be a non-empty string/],
  ['click_element', {}, /id must be a non-empty string/],
  ['click_element', { id: 'x'.repeat(501) }, /id must be at most 500/],
  ['set_text', { id: 'abc', text: 5 }, /text must be a string/],
]) {
  const result = await call(name, args)
  assert.equal(result.isError, true, `${name} ${JSON.stringify(args)}`)
  assert.match(result.content[0].text, pattern)
}
// Without that display, a11y.py answers an error, which comes back as a tool error, not a crash.
for (const [name, args] of [['elements', {}], ['read_text', {}], ['click_element', { id: '--help' }], ['set_text', { id: 'a-1-0-abcdef', text: '-x' }]]) {
  const result = await call(name, args)
  assert.equal(result.isError, true, name)
  assert.ok(result.content[0].text.length > 0, name)
}
send({ jsonrpc: '2.0', id: 3, method: 'tools/call', params: { name: 'key', arguments: { combo: 'rm -rf /' } } })
assert.equal((await wait(3)).result.isError, true)
send({ jsonrpc: '2.0', id: 4, method: 'tools/call', params: { name: 'nope', arguments: {} } })
assert.equal((await wait(4)).error.code, -32602)
send({ jsonrpc: '2.0', id: 5, method: 'bogus' })
assert.equal((await wait(5)).error.code, -32601)
server.kill()
console.log('caboose-desktop-mcp protocol self-test passed')
