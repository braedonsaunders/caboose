// The runtime check's probe (see ../run.sh). It records what the policy blocked and what
// the bridge answered, then writes probe-<load>.json into its data directory.
const results = { violations: [] }
document.addEventListener('securitypolicyviolation', event => results.violations.push(event.effectiveDirective))
const sleep = ms => new Promise(resolve => setTimeout(resolve, ms))
const load = Number(localStorage.getItem('loads') ?? 0) + 1
localStorage.setItem('loads', String(load))
results.load = load
results.app = window.caboose?.app?.id ?? null

// Script that must not run.
const inline = document.createElement('script')
inline.textContent = 'window.__inline = true'
document.head.append(inline)
for (const src of ['data:text/javascript,window.__data=true',
  URL.createObjectURL(new Blob(['window.__blob = true'], { type: 'text/javascript' }))]) {
  const script = document.createElement('script')
  script.src = src
  document.head.append(script)
}
try { eval('window.__eval = true') } catch {}
try { new Function('window.__function = true')() } catch {}
const remote = document.createElement('iframe')
remote.src = 'https://example.com/'
document.body.append(remote)
await sleep(1500)
results.frameTitle = window.__frameTitle ?? null
results.ran = { inline: !!window.__inline, data: !!window.__data, blob: !!window.__blob, eval: !!window.__eval, function: !!window.__function }

// The bridge.
results.exec = await caboose.exec(['sh', '-c', 'printf "%s" "$X"; printf err >&2; exit 3'], { env: { X: 'hello' } })
results.timeout = await caboose.exec(['sleep', '5'], { timeoutMs: 300 })
// Input far larger than a pipe, to a program that never reads it: the deadline still holds.
const big = 'x'.repeat(4 * 1024 * 1024)
const fed = performance.now()
results.stdinTimeout = await caboose.exec(['bash', '-c', 'exec -a caboose-check-feeder sleep 600'], { stdin: big, timeoutMs: 500 })
results.stdinTimeoutMs = Math.round(performance.now() - fed)
// The same, with a long deadline and never awaited: replacing the page must end it.
caboose.exec(['bash', '-c', `exec -a caboose-check-stuck-${load} sleep 600`], { stdin: big, timeoutMs: 600000 }).catch(() => {})
results.badArgv = await caboose.exec('ls').then(() => 'allowed', error => error.message)
results.undeclared = await caboose.notify('x').then(() => 'allowed', error => error.message)
await caboose.files.writeJSON('nested/value.json', { a: 1 })
results.files = await caboose.files.readJSON('nested/value.json')
results.outside = await caboose.files.readText('/etc/hostname').then(() => 'allowed', error => error.message)
let out = ''
const echo = await caboose.spawn(['sh', '-c', 'echo one; echo two'], { onStdout: text => { out += text } })
results.stream = { ...(await echo.exited), out }
// A program that must end when this page is replaced.
results.sleeper = (await caboose.spawn(['bash', '-c', `exec -a caboose-check-sleeper-${load} sleep 600`])).pid

// The network origin, against a server that allows no cross-origin reads.
if (load === 1) {
  await caboose.spawn(['python3', `${caboose.app.dir}/upstream.py`, '18081'])
  for (let i = 0; i < 50; i++) {
    if ((await caboose.exec(['python3', '-c', 'import socket; socket.create_connection(("127.0.0.1", 18081), 1)'])).code === 0) break
    await sleep(100)
  }
  results.directFetch = await fetch('http://127.0.0.1:18081/echo').then(() => 'read', error => error.name)
  const echoed = await caboose.fetch('http://127.0.0.1:18081/echo', {
    method: 'POST', body: 'hi', headers: { 'X-Probe': '1', 'User-Agent': 'probe-agent', Cookie: 'c=1' },
  })
  results.net = { status: echoed.status, url: echoed.headers.get('X-Caboose-Url'), ...(await echoed.json()) }
  const pixel = new Image()
  pixel.src = caboose.net.url('http://127.0.0.1:18081/pixel.png')
  results.netImage = await pixel.decode().then(() => pixel.naturalWidth, error => String(error))
  results.netRefused = await caboose.fetch('http://127.0.0.1:9/').then(response => response.status, error => error.name)
  // A media element streams through it too; loading its metadata needs no sound device.
  const audio = new Audio()
  audio.preload = 'metadata'
  results.netAudio = await new Promise(resolve => {
    audio.addEventListener('loadedmetadata', () => resolve(Math.round(audio.duration)), { once: true })
    audio.addEventListener('error', () => resolve(`error ${audio.error?.code}`), { once: true })
    setTimeout(() => resolve('timeout'), 10000)
    audio.src = caboose.net.url('http://127.0.0.1:18081/tone.wav')
  })

}

// Navigation away by script is refused; the page stays.
location.assign('https://example.com/')
await sleep(800)
results.stayed = location.protocol === 'caboose-app:'

await caboose.files.writeJSON(`probe-${load}.json`, results)
document.getElementById('state').textContent = 'Done'
