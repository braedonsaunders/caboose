import { execFile } from 'node:child_process'
import { promisify } from 'node:util'
import { networkSlot } from './network.js'

const exec = promisify(execFile)
type Run = (binary: string, args: string[]) => Promise<void>
async function runPrivileged(binary: string, args: string[]): Promise<void> {
  const root = process.getuid?.() === 0
  await exec(root ? binary : 'sudo', root ? args : ['-n', binary, ...args], { timeout: 15_000 })
}

/** Install a bidirectional IPv4/IPv6 drop before the guest may resume. */
export function templateNetworkFence(slot: number, run: Run = runPrivileged) {
  return templateNetworkFenceForTap(networkSlot(slot).tap, run)
}

/** The source builder uses a separately allocated disposable TAP. */
export function templateNetworkFenceForTap(tap: string, run: Run = runPrivileged) {
  if (!/^(?:caboose|dsk)[0-9]{1,9}$/.test(tap)) throw new Error('Invalid template TAP')
  const comment = `caboose-template-${tap}`
  const rules: [string, string[]][] = []
  for (const binary of ['iptables', 'ip6tables']) {
    for (const [chain, direction] of [['INPUT', '-i'], ['OUTPUT', '-o'], ['FORWARD', '-i'], ['FORWARD', '-o']] as const) {
      rules.push([binary, [chain, direction, tap, '-m', 'comment', '--comment', comment, '-j', 'DROP']])
    }
  }
  return {
    async hold(): Promise<void> {
      // A failed partial installation remains in place. No VMM may be started
      // after this method throws, and retry/cleanup is an operator action.
      for (const [binary, [chain, ...args]] of rules) await run(binary, ['-w', '-I', chain!, '1', ...args])
    },
    async release(): Promise<void> {
      // Duplicates are possible after a crash/retry. Each deletion is preceded
      // by a check; a failed deletion propagates instead of pretending success.
      for (const [binary, rule] of rules) {
        for (;;) {
          try { await run(binary, ['-w', '-C', ...rule]) } catch (error) {
            const exitCode = (error as { code?: unknown }).code
            if (exitCode === 1) break
            throw error
          }
          await run(binary, ['-w', '-D', ...rule])
        }
      }
    },
  }
}
