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
const text = content => content.map(part => part.text ?? '').join('\n')
const idOf = (listing, name) => listing.split('\n').find(line => line.includes(` "${name}"`))?.split(' ')[0]
try {
  const listing = text(await call('look'))
  const entry = idOf(listing, 'File name')
  assert.ok(entry && listing.includes(`${entry} text "File name" = "report.txt"`), listing)
  const changed = text(await call('act', { steps: [{ set: entry, text: 'batch.txt' }] }))
  assert.match(changed, /^Done\./)
  assert.ok(changed.includes(`~ ${entry} text "File name" = "batch.txt"`), changed)
  const stopped = text(await call('act', { steps: [
    { set: entry, text: 'before-error.txt' },
    { press: 'e999999' },
    { set: entry, text: 'must-not-run.txt' },
  ] }))
  assert.match(stopped, /^Did 1 of 3; stopped: stale id/)
  assert.ok(stopped.includes('"before-error.txt"') && !stopped.includes('must-not-run'), stopped)
  const plain = await call('screenshot')
  assert.equal(plain.length, 1)
  const marked = await call('screenshot', { marks: true })
  assert.equal(marked[0].mimeType, 'image/png')
  assert.ok(Buffer.from(marked[0].data, 'base64').subarray(0, 8).equals(Buffer.from([137,80,78,71,13,10,26,10])))
  assert.ok(marked[1].text.split('\n').some(line => line.split(' ')[1] === entry), marked[1].text)
  const times = []
  for (let i = 0; i < 20; i++) {
    const start = performance.now()
    await call('look')
    times.push(performance.now() - start)
  }
  times.sort((a, b) => a - b)
  console.log(`PASS high-APM act, stale ID halt, changes, values, marks; warm look median=${times[10].toFixed(1)}ms p95=${times[19].toFixed(1)}ms`)
} finally {
  child.stdin.end()
  child.kill()
}
