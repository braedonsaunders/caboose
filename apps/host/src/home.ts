import type { AgentGuest } from './agents.js'

/**
 * Everything in /home/caboose belongs to user caboose. A process run as root with
 * HOME=/home/caboose (a hand-run command, an older image's session script) leaves
 * root-owned caches behind — ~/.npm, ~/.cache, ~/.local — and every later npm, uv or agent
 * run as caboose then fails on them. Before the host installs, signs in or starts an agent,
 * it gives anything in the home that is not caboose's back to caboose. One pass, as root,
 * on the computer's own filesystem only; it prints how many entries it changed.
 */
export const HOME_REPAIR_SCRIPT = [
  'cd /home/caboose 2>/dev/null || { echo 0; exit 0; }',
  'timeout 60 find /home/caboose -xdev \\( ! -user caboose -o ! -group caboose \\) -printf . -exec chown -h caboose:caboose {} + 2>/dev/null | wc -c',
].join('\n')

/** Runs the repair at most once per interval; a failed repair never blocks the operation. */
export class HomeOwnership {
  private checkedAt = Number.NEGATIVE_INFINITY

  constructor(private readonly intervalMs = 5 * 60_000, private readonly now = () => Date.now()) {}

  async ensure(guest: AgentGuest): Promise<number> {
    if (this.now() - this.checkedAt < this.intervalMs) return 0
    this.checkedAt = this.now()
    const output = await guest.run('/bin/sh', ['-c', HOME_REPAIR_SCRIPT], 90_000).catch(error => {
      console.error('Could not check the ownership of the computer\'s home:', error)
      return '0'
    })
    const fixed = Number.parseInt(output.trim(), 10) || 0
    if (fixed > 0) console.warn(`Gave ${fixed} entries in /home/caboose back to user caboose.`)
    return fixed
  }

  /** A restarted or replaced computer is checked again on its first agent operation. */
  reset(): void { this.checkedAt = Number.NEGATIVE_INFINITY }
}
