import { test } from 'vitest'
import assert from 'node:assert/strict'
import { createServer } from 'node:http'
import { spawn } from 'node:child_process'
import { once } from 'node:events'
import { fileURLToPath } from 'node:url'

async function runCheck(mode) {
  let state = 'parked', content = Buffer.alloc(0), version = 'v1'
  const server = createServer(async (req, res) => {
    const url = new URL(req.url, 'http://localhost')
    const path = url.pathname
    if (path === '/v1/computer') return res.end(JSON.stringify({ state }))
    if (path === '/v1/session') { state = 'running'; return res.end('{}') }
    if (path === '/v1/session/park') { state = 'parked'; return res.end('{}') }
    if (path === '/v1/fs/changes') { state = 'running'; return res.end('{}') }
    if (path === '/v1/fs/mkdir' || path === '/v1/fs/item') { state = 'running'; req.resume(); return res.end('{}') }
    if (path === '/v1/fs/content' && req.method === 'PUT') {
      state = 'running'; const chunks = []; for await (const chunk of req) chunks.push(chunk); content = Buffer.concat(chunks); version = version === 'v1' ? 'v2' : 'v3'; return res.end('{}')
    }
    if (mode === 'unexpected-wake' && state === 'parked') state = 'running'
    const item = { name: 'note.txt', etag: version, size: content.length }
    if (path === '/v1/fs/stat') return res.end(JSON.stringify(item))
    if (path === '/v1/fs/list') return res.end(JSON.stringify({ items: [item] }))
    if (path === '/v1/fs/content') {
      if (req.headers['if-match'] === '"definitely-not-the-version"') { res.writeHead(412); return res.end('{}') }
      if (req.headers.range) { res.writeHead(206, { 'content-range': `bytes 2-8/${content.length}` }); return res.end(content.subarray(2, 9)) }
      return res.end(content)
    }
    res.writeHead(404); res.end()
  })
  server.listen(0, '127.0.0.1'); await once(server, 'listening')
  try {
    const child = spawn(process.execPath, [fileURLToPath(new URL('./check-parked-files.mjs', import.meta.url))], { env: { ...process.env, CABOOSE_URL: `http://127.0.0.1:${server.address().port}`, CABOOSE_OWNER_TOKEN: 'test', CABOOSE_DISPOSABLE_CHECK: 'yes' }, stdio: ['ignore', 'pipe', 'pipe'] })
    let output = ''; child.stdout.on('data', x => { output += x }); child.stderr.on('data', x => { output += x })
    const [code] = await once(child, 'close')
    return { code, output }
  } finally { server.closeAllConnections(); await new Promise(resolve => server.close(resolve)) }
}

test('check exercises parked reads, cancellation and wake fallbacks', async () => {
  const result = await runCheck('normal')
  assert.equal(result.code, 0, result.output)
  assert.match(result.output, /mutation thaw passed/)
})

test('check fails when a supposed parked read wakes the computer', async () => {
  const result = await runCheck('unexpected-wake')
  assert.notEqual(result.code, 0)
  assert.match(result.output, /computer should remain parked/)
})
