import { execFile } from 'node:child_process'
import { promisify } from 'node:util'
import { existsSync } from 'node:fs'

const run = promisify(execFile)
export function seatStarter(execute = run) {
  let starting
  return async () => {
    starting ??= (async () => {
      if (execute === run && !existsSync('/usr/local/libexec/caboose-agent-seat') && process.env.CABOOSE_DISPLAY_CONTROL) return { ...process.env }
      await execute('sudo', ['-n', '/usr/local/libexec/caboose-agent-seat'], { timeout: 180_000 })
      const { stdout } = await execute('/bin/sh', ['-c', 'set -a; . /run/caboose/agent-display.env; env -0'], { timeout: 5000 })
      return Object.fromEntries(stdout.split('\0').filter(line => line.includes('=')).map(line => {
        const at = line.indexOf('=')
        return [line.slice(0, at), line.slice(at + 1)]
      }))
    })().finally(() => { starting = undefined })
    return starting
  }
}
/** Start the agent seat on first GUI use and read its environment as the owner. */
export const ensureAgentSeat = seatStarter()
