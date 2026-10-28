// Self-test with Node only (no browser): node guest/media-handoff/selftest.mjs
// Covers the native messaging framing, the state file, the command relay, the URL
// classification the content script uses, and the extension ID the install registers.
import assert from 'node:assert/strict'
import { spawn } from 'node:child_process'
import { createHash } from 'node:crypto'
import { existsSync, mkdirSync, mkdtempSync, readFileSync, renameSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { runInNewContext } from 'node:vm'

const here = new URL('.', import.meta.url).pathname

// The extension ID is the first 128 bits of SHA-256 of the public key, written a–p.
const manifest = JSON.parse(readFileSync(join(here, 'manifest.json'), 'utf8'))
const hex = createHash('sha256').update(Buffer.from(manifest.key, 'base64')).digest('hex').slice(0, 32)
const extensionId = [...hex].map(digit => String.fromCharCode(97 + parseInt(digit, 16))).join('')
assert.equal(extensionId, 'cklinclacpchpdgickgonlhnldfmkhbh')
assert.match(readFileSync(join(here, 'install.sh'), 'utf8'), new RegExp(`extension_id=${extensionId}\\b`))
assert.match(readFileSync(join(here, 'check.sh'), 'utf8'), new RegExp(`extension=${extensionId}\\b`))

// The content script's classification.
const context = { URL }
context.globalThis = context
runInNewContext(readFileSync(join(here, 'media-kind.js'), 'utf8'), context)
const { classify, youtubeVideoId, cleanTitle, duration, ID_PATTERN } = context.CabooseMedia
const plain = value => JSON.parse(JSON.stringify(value))
assert.deepEqual(plain(classify('https://www.youtube.com/watch?v=jNQXAC9IVRw&t=4', 'blob:https://www.youtube.com/0b1c')), { kind: 'youtube', videoId: 'jNQXAC9IVRw' })
for (const page of ['https://youtu.be/jNQXAC9IVRw', 'https://www.youtube-nocookie.com/embed/jNQXAC9IVRw?autoplay=1',
  'https://m.youtube.com/shorts/jNQXAC9IVRw', 'https://www.youtube.com/live/jNQXAC9IVRw']) {
  assert.equal(youtubeVideoId(page), 'jNQXAC9IVRw', page)
}
assert.equal(youtubeVideoId('https://www.youtube.com/'), undefined)
assert.equal(youtubeVideoId('https://notyoutube.com/watch?v=jNQXAC9IVRw'), undefined)
assert.equal(youtubeVideoId('https://www.youtube.com/watch?v=short'), undefined)
assert.deepEqual(plain(classify('https://example.com/a', 'https://cdn.example.com/live/index.M3U8?token=x')), { kind: 'hls', src: 'https://cdn.example.com/live/index.M3U8?token=x' })
assert.deepEqual(plain(classify('https://example.com/a', 'http://cdn.example.com/movie.mp4')), { kind: 'video', src: 'http://cdn.example.com/movie.mp4' })
assert.equal(classify('https://example.com/a', 'blob:https://example.com/9f2c'), undefined)
assert.equal(classify('https://example.com/a', 'data:video/mp4;base64,AAAA'), undefined)
assert.equal(classify('https://example.com/a', ''), undefined)
assert.equal(cleanTitle('(3) A talk - YouTube'), 'A talk')
assert.equal(cleanTitle(undefined), '')
assert.equal(duration(Infinity), null)
assert.equal(duration(Number.NaN), null)
assert.equal(duration(12.5), 12.5)
assert.ok(ID_PATTERN.test('1944008823.0.0gqc72sh-1') && !ID_PATTERN.test('a/b') && !ID_PATTERN.test('x'.repeat(65)))

// The native host, with a throwaway HOME.
const home = mkdtempSync(join(tmpdir(), 'caboose-media-'))
const dir = join(home, '.cache', 'caboose')
const state = join(dir, 'media.json')
const commandFile = join(dir, 'media-command.json')
mkdirSync(dir, { recursive: true })
writeFileSync(state, '{"stale":true}')
// A command from before the host started must not be replayed.
writeFileSync(commandFile, JSON.stringify({ seq: 100, id: 'old.0.a-1', action: 'pause' }))
const host = spawn(process.execPath, [join(here, 'caboose-media-host.mjs'), `chrome-extension://${extensionId}/`], {
  env: { ...process.env, HOME: home }, stdio: ['pipe', 'pipe', 'pipe'],
})
let stderr = ''
host.stderr.on('data', chunk => { stderr += chunk })
const received = []
let pending = Buffer.alloc(0)
host.stdout.on('data', chunk => {
  pending = Buffer.concat([pending, chunk])
  while (pending.length >= 4 && pending.length >= 4 + pending.readUInt32LE(0)) {
    const length = pending.readUInt32LE(0)
    received.push(JSON.parse(pending.subarray(4, 4 + length).toString('utf8')))
    pending = pending.subarray(4 + length)
  }
})
function frame(message) {
  const body = Buffer.from(JSON.stringify(message), 'utf8')
  const header = Buffer.alloc(4)
  header.writeUInt32LE(body.length, 0)
  return Buffer.concat([header, body])
}
const wait = async (what, test) => {
  for (let i = 0; i < 300; i++) {
    const value = test()
    if (value) return value
    await new Promise(resolve => setTimeout(resolve, 10))
  }
  throw new Error(`timed out waiting for ${what}; host stderr: ${stderr}`)
}
const read = () => { try { return JSON.parse(readFileSync(state, 'utf8')) } catch { return undefined } }
function command(value) {
  writeFileSync(`${commandFile}.tmp`, JSON.stringify(value))
  renameSync(`${commandFile}.tmp`, commandFile)
}

await wait('the pid file', () => existsSync(join(dir, 'media-host.pid')))
assert.equal(existsSync(state), false, 'a new host clears the previous session state')
assert.equal(readFileSync(join(dir, 'media-host.pid'), 'utf8').trim(), String(host.pid))

const media = { id: '7.0.k3j9x2-1', page: 'https://www.youtube.com/watch?v=jNQXAC9IVRw', title: 'Me at the zoo', kind: 'youtube',
  videoId: 'jNQXAC9IVRw', position: 4.25, duration: 19.02, paused: false, updatedAt: 1793161915640 }
// Two messages in one write, and one split across writes, exercise the framing.
const two = Buffer.concat([frame({ type: 'media', media: { ...media, position: 1 } }), frame({ type: 'media', media })])
host.stdin.write(two.subarray(0, 7))
await new Promise(resolve => setTimeout(resolve, 30))
host.stdin.write(two.subarray(7))
assert.deepEqual(await wait('the state file', () => read()?.position === 4.25 && read()), media)

host.stdin.write(frame({ type: 'media', media: { ...media, id: 'bad/id', position: 9 } }))
host.stdin.write(frame({ type: 'media', media: { ...media, kind: 'video', videoId: undefined, src: 'blob:x' } }))
host.stdin.write(frame({ type: 'media', media: { ...media, kind: 'hls', videoId: undefined, src: 'https://cdn.example.com/a.m3u8', duration: null } }))
assert.equal((await wait('the hls state', () => read()?.kind === 'hls' && read())).duration, null)
assert.match(stderr, /malformed media state/)

host.stdin.write(frame({ type: 'media', media: null }))
await wait('the state file to be removed', () => !existsSync(state))

command({ seq: 99, id: '7.0.k3j9x2-1', action: 'play' })
command({ seq: 101, id: '7.0.k3j9x2-1', action: 'play', position: 42.5 })
await wait('a relayed command', () => received.length >= 1)
command({ seq: 101, id: '7.0.k3j9x2-1', action: 'pause' })
command({ seq: 102, id: '7.0.k3j9x2-1', action: 'rewind' })
command({ seq: 103, id: '../etc', action: 'pause' })
command({ seq: 104, id: '7.0.k3j9x2-1', action: 'pause' })
await wait('a second relayed command', () => received.length >= 2)
await new Promise(resolve => setTimeout(resolve, 1200))
assert.deepEqual(received, [
  { type: 'command', id: '7.0.k3j9x2-1', action: 'play', position: 42.5 },
  { type: 'command', id: '7.0.k3j9x2-1', action: 'pause' },
])

host.stdin.write(frame({ type: 'media', media }))
await wait('the state file again', () => read())
const exited = new Promise(resolve => host.once('exit', resolve))
host.stdin.end()
assert.equal(await exited, 0)
assert.equal(existsSync(state), false, 'closing the browser clears the state')
assert.equal(existsSync(join(dir, 'media-host.pid')), false)
rmSync(home, { recursive: true, force: true })
console.log('caboose media handoff self-test passed')
