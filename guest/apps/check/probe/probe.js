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
results.ran = { inline: !!window.__inline, data: !!window.__data, blob: !!window.__blob, eval: !!window.__eval, function: !!window.__function }

// The bridge.
results.exec = await caboose.exec(['sh', '-c', 'printf "%s" "$X"; printf err >&2; exit 3'], { env: { X: 'hello' } })
results.timeout = await caboose.exec(['sleep', '5'], { timeoutMs: 300 })
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

// Navigation away by script is refused; the page stays.
location.assign('https://example.com/')
await sleep(800)
results.stayed = location.protocol === 'caboose-app:'

await caboose.files.writeJSON(`probe-${load}.json`, results)
document.getElementById('state').textContent = 'Done'
