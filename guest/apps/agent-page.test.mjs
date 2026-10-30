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
  vm.runInContext(page.replace('__CABOOSE_APP__', JSON.stringify({ id: 'notes', capabilities: ['exec'] }))
    .replace('__CABOOSE_NET__', 'null'), context)
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

/** The page script alone, with a stand-in relay that records requests and answers them. */
function loadPage(netBase, answer = () => null) {
  const listeners = []
  const requests = []
  const fetches = []
  const context = vm.createContext({
    TextEncoder, TextDecoder, Uint8Array, Promise, Object, JSON, String, Number, URL, Headers, Request, TypeError, Error,
    setTimeout,
    btoa: value => Buffer.from(value, 'binary').toString('base64'),
    atob: value => Buffer.from(value, 'base64').toString('binary'),
    location: { origin: 'caboose-app://radio', href: 'caboose-app://radio/index.html' },
    addEventListener: (name, handler) => { if (name === 'message') listeners.push(handler) },
    fetch: async (url, init) => { fetches.push({ url, init }); return { ok: true } },
  })
  const top = vm.runInContext('globalThis', context)
  context.window = top
  const deliver = data => {
    const event = { source: top, origin: context.location.origin, data, stopImmediatePropagation() {} }
    for (const handler of [...listeners]) handler(event)
  }
  context.postMessage = data => {
    if (data.caboose === 'request') {
      requests.push(data)
      queueMicrotask(() => deliver({ caboose: 'reply', id: data.id, ok: true, value: answer(data) }))
    } else deliver(data)
  }
  vm.runInContext(page.replace('__CABOOSE_APP__', JSON.stringify({ id: 'radio', capabilities: ['net'] }))
    .replace('__CABOOSE_NET__', JSON.stringify(netBase)), context)
  return { caboose: context.caboose, requests, fetches, deliver }
}

test('caboose.net maps any http(s) URL onto the network origin', async () => {
  const base = 'http://127.0.0.1:4000/' + 'ab'.repeat(16) + '/'
  const { caboose, fetches } = loadPage(base)
  assert.equal(caboose.net.url('https://api.example.com/v1/items?q=a b'), `${base}https/api.example.com/v1/items?q=a%20b`)
  assert.equal(caboose.net.url('http://radio.example:8000/live'), `${base}http/radio.example%3A8000/live`)
  assert.equal(caboose.net.url('http://[::1]:8080/'), `${base}http/%5B%3A%3A1%5D%3A8080/`)
  assert.throws(() => caboose.net.url('ftp://a.example/'), /http and https/)
  assert.throws(() => caboose.net.url('https://user:pass@a.example/'), /header/)
  await caboose.fetch('https://api.example.com/x', {
    method: 'POST', body: '{}', headers: { 'Content-Type': 'application/json', Cookie: 'a=1', 'User-Agent': 'VLC' },
  })
  const [{ url, init }] = fetches
  assert.equal(url, `${base}https/api.example.com/x`)
  assert.equal(init.method, 'POST')
  assert.equal(init.body, '{}')
  assert.equal(init.credentials, 'omit')
  assert.equal(init.headers.get('content-type'), 'application/json')
  assert.equal(init.headers.get('x-caboose-header-cookie'), 'a=1')
  assert.equal(init.headers.get('x-caboose-header-user-agent'), 'VLC')
  assert.equal(init.headers.get('cookie'), null)
})

test('without net, caboose.fetch says which capability to declare', async () => {
  const { caboose } = loadPage(null)
  await assert.rejects(caboose.fetch('https://api.example.com/'), /"net" capability/)
})
