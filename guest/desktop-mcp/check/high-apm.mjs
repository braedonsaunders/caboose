import { spawn } from 'node:child_process'
import { createInterface } from 'node:readline'
import assert from 'node:assert/strict'
const child = spawn('node', ['/opt/caboose/desktop-mcp.mjs'], { env: { ...process.env, CABOOSE_AGENT_DISPLAY: ':101' }, stdio: ['pipe', 'pipe', 'inherit'] })
const pending = new Map()
let id = 0
createInterface({ input: child.stdout }).on('line', line => {
  const answer = JSON.parse(line)
  pending.get(answer.id)?.(answer)
  pending.delete(answer.id)
})
async function call(name, args = {}) {
  const key = ++id
  console.log(`high-APM request ${key}: ${name}`)
  const answer = new Promise(resolve => pending.set(key, resolve))
  child.stdin.write(JSON.stringify({ jsonrpc: '2.0', id: key, method: 'tools/call', params: { name, arguments: args } }) + '\n')
  let timer
  const result = (await Promise.race([answer, new Promise((_, reject) => {
    timer = setTimeout(() => reject(new Error(`high-APM request ${key} (${name}) did not answer in 45s`)), 45_000)
  })])).result
  clearTimeout(timer)
  console.log(`high-APM response ${key}: ${name}`)
  assert.ok(!result.isError, JSON.stringify(result))
  return result.content
}
const json = content => JSON.parse(content[0].text)
try {
  const elements = json(await call('elements')).elements
  const entry = elements.find(e => e.name === 'File name')
  assert.equal(entry.value, 'report.txt')
  const changed = json(await call('batch', { steps: [{ action: 'set_text', id: entry.id, text: 'batch.txt' }] }))
  assert.equal(changed.completed, 1)
  assert.equal(changed.state.elements.find(e => e.id === entry.id).value, 'batch.txt')
  const stopped = json(await call('batch', { steps: [
    { action: 'set_text', id: entry.id, text: 'before-error.txt' },
    { action: 'click_element', id: entry.id.replace(/-[^-]+$/, '-ffffff') },
    { action: 'set_text', id: entry.id, text: 'must-not-run.txt' },
  ] }))
  assert.equal(stopped.completed, 1)
  assert.match(stopped.error, /element not found/)
  assert.equal(stopped.state.elements.find(e => e.id === entry.id).value, 'before-error.txt')
  const observed = await call('set_text', { id: entry.id, text: 'observed.txt', observe: true })
  assert.equal(JSON.parse(observed[1].text).state.elements.find(e => e.id === entry.id).value, 'observed.txt')
  const plain = await call('screenshot')
  assert.equal(plain.length, 1)
  const marked = await call('screenshot', { annotate: true })
  assert.equal(marked[0].mimeType, 'image/png')
  assert.ok(Buffer.from(marked[0].data, 'base64').subarray(0, 8).equals(Buffer.from([137,80,78,71,13,10,26,10])))
  assert.ok(JSON.parse(marked[1].text).some(e => e.id === entry.id && e.mark > 0))
  const times = []
  for (let i = 0; i < 20; i++) {
    const start = performance.now()
    await call('elements')
    times.push(performance.now() - start)
  }
  times.sort((a, b) => a - b)
  console.log(`PASS high-APM batch, stale ID halt, observe, values, annotations; warm elements median=${times[10].toFixed(1)}ms p95=${times[19].toFixed(1)}ms`)
} finally {
  child.stdin.end()
  child.kill()
}
