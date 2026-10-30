import { execFile } from 'node:child_process'
import { promisify } from 'node:util'
import { existsSync, statSync } from 'node:fs'
import { createConnection } from 'node:net'

const run = promisify(execFile)
export function controlAlive(env) {
  if (!env?.CABOOSE_DISPLAY_CONTROL) return Promise.resolve(false)
  return new Promise(resolve => {
    const socket = createConnection(env.CABOOSE_DISPLAY_CONTROL)
    let data = ''
    const done = alive => { socket.destroy(); resolve(alive) }
    socket.setTimeout(500, () => done(false))
    socket.on('error', () => done(false))
    socket.on('end', () => done(false))
    socket.on('connect', () => socket.write('windows\n'))
    socket.on('data', chunk => {
      data += chunk
      if (data.length > 1 << 20) return done(false)
      if (data.includes('\n')) {
        try { done(JSON.parse(data.split('\n')[0]).ok === true) } catch { done(false) }
      }
    })
  })
}
export function seatStarter(execute = run, alive = controlAlive, exists = existsSync) {
  let starting, cached
  const read = async () => {
    const { stdout } = await execute('/usr/bin/python3', ['/opt/caboose/agent-profile.py', 'exec', '/bin/sh', '-c', 'set -a; unset CABOOSE_DISPLAY_CONTROL; . /run/caboose/agent-display.env; env -0'], { timeout: 5000 })
    return Object.fromEntries(stdout.split('\0').filter(line => line.includes('=')).map(line => {
      const at = line.indexOf('=')
      return [line.slice(0, at), line.slice(at + 1)]
    }))
  }
  const start = async () => {
    starting ??= (async () => {
      if (cached && await alive(cached)) return cached
      cached = undefined
      if (execute === run && !exists('/usr/local/libexec/caboose-agent-seat') && process.env.CABOOSE_DISPLAY_CONTROL) return (cached = { ...process.env })
      try {
        if (exists('/run/caboose/agent-display.env') && (execute !== run || statSync('/run/caboose/agent-display.env').size > 0)) {
          const env = await read()
          if (await alive(env)) return (cached = env)
        }
      } catch {}
      await execute('sudo', ['-n', '/usr/local/libexec/caboose-agent-seat'], { timeout: 180_000 })
      return (cached = await read())
    })().finally(() => { starting = undefined })
    return starting
  }
  start.invalidate = () => { cached = undefined }
  return start
}
export const ensureAgentSeat = seatStarter()
