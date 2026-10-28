import { execFile } from 'node:child_process'
import { once } from 'node:events'
import { createServer } from 'node:http'
import { fileURLToPath } from 'node:url'
import { promisify } from 'node:util'
import { expect, it } from 'vitest'

const execute = promisify(execFile)
const script = fileURLToPath(new URL('./check-computers.mjs', import.meta.url))

// Exercise the real command in a child process, including its cleanup after failed HTTP calls.
async function run({ legacy = false, fail = null } = {}) {
  const requests = []
  const owner = { id: 'owner', state: 'running', settings: { name: 'Owner' } }
  let tenant = false
  let computer = false
  let revoked = false
  let paired = false
  let running = false
  const made = () => ({ id: 'c-0123456789', state: running ? 'running' : 'parked', settings: { name: 'Caboose check', memoryMb: 2048, vcpus: 2 } })
  const server = createServer(async (request, response) => {
    let raw = ''
    for await (const chunk of request) raw += chunk
    const body = raw ? JSON.parse(raw) : undefined
    const path = request.url
    const key = `${request.method} ${path}`
    requests.push({ key, body })
    const reply = (status, value = {}) => {
      response.writeHead(status, { 'content-type': 'application/json' })
      response.end(JSON.stringify(value))
    }
    if (key === 'GET /v1/tenants') return reply(legacy ? 404 : 200, legacy ? { error: 'not found' } : { tenants: [] })
    if (key === 'POST /v1/tenants') { tenant = true; return reply(201, { id: 'test-tenant' }) }
    if (key === 'GET /v1/computers' && request.headers.authorization === 'Bearer phone-token') return reply(403)
    if (key === 'GET /v1/computers') return reply(200, { computers: [owner, ...(computer ? [made()] : [])], canCreate: true })
    if (key === 'POST /v1/computers') {
      if (fail === 'create') return reply(500)
      if (!legacy && (!tenant || body.tenantId !== 'test-tenant')) return reply(400)
      computer = true
      return reply(201, made())
    }
    if (key === 'POST /v1/computers/c-0123456789/session') {
      if (fail === 'wake') return reply(500)
      running = true
      return reply(200, { state: 'running', computer: { name: 'Caboose check' } })
    }
    if (key === 'POST /v1/computers/c-0123456789/pairing') return reply(201, { code: 'TEST2345' })
    if (key === 'POST /v1/pair') {
      if (paired) return reply(404)
      paired = true
      return reply(201, { token: 'phone-token', computer: { id: 'c-0123456789' } })
    }
    if (key === 'GET /v1/computer') return reply(revoked ? 401 : 200, { settings: { name: 'Caboose check' } })
    if (key === 'GET /v1/health' || key === 'GET /v1/computers/owner/computer') return reply(403)
    if (key === 'GET /v1/computers/c-0123456789/phones') return reply(200, { phones: [{ id: 'test-phone', name: 'Caboose check' }] })
    if (key === 'DELETE /v1/computers/c-0123456789/phones/test-phone') { revoked = true; return reply(200) }
    if (key === 'GET /v1/computers/c-0123456789') {
      if (fail === 'poll' && computer) return reply(500)
      return reply(computer ? 200 : 404, made())
    }
    if (key === 'DELETE /v1/computers/c-0123456789') {
      if (fail === 'delete') return reply(500)
      computer = false
      return reply(200, { deleted: true })
    }
    if (key === 'DELETE /v1/tenants/test-tenant') {
      if (computer) return reply(409)
      tenant = false
      return reply(200, { deleted: true })
    }
    return reply(500, { error: `Unexpected request: ${key}` })
  })
  server.listen(0, '127.0.0.1')
  await once(server, 'listening')
  try {
    const result = await execute(process.execPath, [script], {
      env: { ...process.env, CABOOSE_URL: `http://127.0.0.1:${server.address().port}`, CABOOSE_OWNER_TOKEN: 'test-owner' }, timeout: 10_000,
    }).then(output => ({ ...output, code: 0 }), error => ({ stdout: error.stdout, stderr: error.stderr, code: error.code }))
    return { ...result, requests, tenant, computer }
  } finally {
    server.closeAllConnections()
    await new Promise(resolve => server.close(resolve))
  }
}

it.each([false, true])('cleans up a successful check (legacy host: %s)', async legacy => {
  const result = await run({ legacy })
  expect(result.code, result.stderr).toBe(0)
  expect(result.stdout).toContain('Computers check passed.')
  expect(result.tenant).toBe(false)
  expect(result.computer).toBe(false)
  const create = result.requests.find(request => request.key === 'POST /v1/computers')
  expect(create.body.tenantId).toBe(legacy ? undefined : 'test-tenant')
  const deletes = result.requests.filter(request => request.key.startsWith('DELETE ')).map(request => request.key)
  expect(deletes).toEqual(['DELETE /v1/computers/c-0123456789/phones/test-phone', 'DELETE /v1/computers/c-0123456789', ...(!legacy ? ['DELETE /v1/tenants/test-tenant'] : [])])
})

it.each(['create', 'wake', 'poll'])('cleans up after a failed %s request', async fail => {
  const result = await run({ fail })
  expect(result.code).not.toBe(0)
  expect(result.stderr).toContain('HTTP 500')
  expect(result.tenant).toBe(false)
  expect(result.computer).toBe(false)
  expect(result.requests.at(-1).key).toBe('DELETE /v1/tenants/test-tenant')
})

it('attempts tenant cleanup even if computer deletion fails and preserves both errors', async () => {
  const result = await run({ fail: 'delete' })
  expect(result.code).not.toBe(0)
  expect(result.stderr).toContain('HTTP 500')
  expect(result.stderr).toContain('HTTP 409')
  expect(result.requests.at(-1).key).toBe('DELETE /v1/tenants/test-tenant')
})
