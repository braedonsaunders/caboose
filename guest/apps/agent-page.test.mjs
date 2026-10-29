import { readFile } from 'node:fs/promises'
import { test } from 'node:test'
import assert from 'node:assert/strict'
import vm from 'node:vm'

const page = await readFile(new URL('./page.js', import.meta.url), 'utf8')
const world = await readFile(new URL('./world.js', import.meta.url), 'utf8')

test('app calls cross the isolated relay and foreign frames cannot issue calls', async () => {
  const listeners = []
  const requests = []
  const context = vm.createContext({
    TextEncoder, TextDecoder, Uint8Array, Promise, Object, JSON, String, Number,
    btoa: value => Buffer.from(value, 'binary').toString('base64'),
    atob: value => Buffer.from(value, 'base64').toString('binary'),
    location: { origin: 'http://127.0.0.1:1234' },
    crypto: { getRandomValues: bytes => { bytes.fill(7); return bytes } },
    addEventListener: (name, handler) => { if (name === 'message') listeners.push(handler) },
    webkit: { messageHandlers: { caboose: { postMessage: async raw => {
      requests.push(JSON.parse(raw))
      return JSON.stringify({ ok: true, value: { code: 0, stdout: 'ok' } })
    } } } },
  })
  const top = vm.runInContext("globalThis", context)
  context.window = top
  context.postMessage = data => {
    const event = { source: top, origin: context.location.origin, data, stopImmediatePropagation() {} }
    for (const handler of listeners) handler(event)
  }
  vm.runInContext(world, context)
  vm.runInContext(page.replace('__CABOOSE_APP__', JSON.stringify({ id: 'notes', capabilities: ['exec'] })), context)
  const result = await context.caboose.exec(['echo', 'ok'])
  assert.equal(result.stdout, 'ok')
  assert.equal(requests.length, 2)
  assert.equal(requests[0].method, "__caboose.ready")
  assert.equal(requests[1].document, '07'.repeat(16))
  assert.equal(requests[1].method, 'exec')
  await context.caboose.notify('Ready', 'Finished')
  await context.caboose.open('https://example.com')
  assert.equal(requests[2].method, 'notify')
  assert.equal(requests[2].params.title, 'Ready')
  assert.equal(requests[3].method, 'open')
  assert.equal(requests[3].params.target, 'https://example.com')
  for (const event of [
    { source: {}, origin: context.location.origin },
    { source: top, origin: 'https://other.example' },
  ]) {
    for (const listener of listeners) listener({ ...event, data: { caboose: 'request', id: 7, method: 'exec', params: {} }, stopImmediatePropagation() {} })
  }
  assert.equal(requests.length, 4)
})
