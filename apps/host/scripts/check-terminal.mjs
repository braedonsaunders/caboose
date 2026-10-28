#!/usr/bin/env node
// Opens a terminal on the configured computer through /v1/terminal (waking it), runs a
// command, resizes, detaches and reattaches from its offset, then exits the shell. Leaves
// nothing behind: the session ends with the check, and a failed check hangs it up.
import { WebSocket } from 'ws'

const base = process.env.CABOOSE_URL
const token = process.env.CABOOSE_OWNER_TOKEN
if (!base || !token) throw new Error('Set CABOOSE_URL and CABOOSE_OWNER_TOKEN')
const headers = { authorization: `Bearer ${token}` }
const socketUrl = query => `${new URL('/v1/terminal', base).toString().replace(/^http/, 'ws')}?${query}`

/** One connection: collects output and control messages, and waits for output to appear. */
function attach(query) {
  const socket = new WebSocket(socketUrl(query), { headers })
  const state = { socket, output: '', controls: [], received: 0, hello: undefined, closed: undefined }
  const waiters = new Set()
  const notify = () => { for (const waiter of waiters) waiter() }
  socket.on('message', (data, binary) => {
    if (binary) { state.output += data.toString('utf8'); state.received += data.length }
    else {
      const message = JSON.parse(data.toString())
      if (message.type === 'hello') { state.hello = message; state.received = message.offset }
      state.controls.push(message)
    }
    notify()
  })
  socket.on('close', (code, reason) => { state.closed = { code, reason: reason.toString() }; notify() })
  socket.on('unexpected-response', (_request, response) => { state.closed = { code: response.statusCode, reason: 'refused' }; notify() })
  socket.on('error', error => { state.closed ??= { code: 0, reason: error.message }; notify() })
  state.until = (test, what, timeoutMs = 300_000) => new Promise((resolve, reject) => {
    const check = () => {
      if (test(state)) { waiters.delete(check); clearTimeout(timer); resolve(state) }
      else if (state.closed) { waiters.delete(check); clearTimeout(timer); reject(new Error(`${what}: closed ${state.closed.code} ${state.closed.reason}\n${state.output.slice(-2000)}`)) }
    }
    const timer = setTimeout(() => { waiters.delete(check); reject(new Error(`${what}: timed out\n${state.output.slice(-2000)}`)) }, timeoutMs)
    waiters.add(check)
    check()
  })
  state.run = (command, marker, what) => { socket.send(Buffer.from(`${command}\r`)); return state.until(s => s.output.includes(marker), what, 30_000) }
  return state
}

let session
try {
  // Wakes a parked computer; the first wake can include a guest component update.
  const first = attach('cols=80&rows=24&wake=1')
  await first.until(s => s.hello, 'hello')
  session = first.hello.session
  console.log(`Session ${session} (reset ${first.hello.reset})`)
  await first.run('echo "caboose-$((6*7)) $TERM $COLORTERM $USER $HOME"', 'caboose-42 ', 'run a command')
  if (!/caboose-42 xterm-256color truecolor caboose \/home\/caboose/.test(first.output)) throw new Error(`unexpected environment: ${first.output.slice(-300)}`)
  first.socket.send(JSON.stringify({ type: 'resize', cols: 132, rows: 40 }))
  await first.run('stty size', '40 132', 'resize')

  const listed = await (await fetch(new URL('/v1/terminal/sessions', base), { headers })).json()
  if (!listed.sessions?.some(s => s.id === session && s.attached && s.cols === 132)) throw new Error(`session list: ${JSON.stringify(listed)}`)

  // Output written while nobody is attached is replayed from the offset the client holds.
  first.socket.send(Buffer.from('sleep 1; echo "detached-$((40+2))"\r'))
  await first.until(s => s.output.includes('sleep 1'), 'echo before detach')
  const offset = first.received
  first.socket.close()
  await first.until(s => s.closed, 'detach')
  await new Promise(resolve => setTimeout(resolve, 2000))
  const second = attach(`cols=100&rows=30&session=${session}&offset=${offset}`)
  await second.until(s => s.hello, 'reattach')
  if (second.hello.reset || second.hello.offset !== offset) throw new Error(`reattach did not continue: ${JSON.stringify(second.hello)}`)
  await second.until(s => s.output.includes('detached-42'), 'replay')
  await second.run('stty size', '30 100', 'resize on reattach')

  second.socket.send(Buffer.from('exit 7\r'))
  await second.until(s => s.closed, 'exit')
  const exit = second.controls.at(-1)
  if (second.closed.code !== 1000 || exit?.type !== 'exit' || exit.code !== 7) throw new Error(`exit: ${JSON.stringify(exit)} ${second.closed.code}`)
  session = undefined
  console.log('Terminal open, run, resize, list, detach and reattach, and exit checks passed')
} finally {
  if (session) await fetch(new URL(`/v1/terminal/sessions/${session}`, base), { method: 'DELETE', headers }).catch(() => {})
}
