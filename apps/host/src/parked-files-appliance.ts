import { spawn, type ChildProcessWithoutNullStreams } from 'node:child_process'
import { fileURLToPath } from 'node:url'

/** A single appliance and sequential bounded RPC stream for one HTTP request. */
export class ParkedAppliance {
  private readonly child: ChildProcessWithoutNullStreams
  private buffer = ''
  private sequence = 0
  private failure: Error | undefined
  private pending: { id?: number; resolve(value: string): void; reject(error: Error): void } | undefined
  private readonly exited: Promise<void>
  readonly ready: Promise<string>

  constructor(image: string) {
    this.ready = new Promise((resolve, reject) => { this.pending = { resolve, reject } })
    this.child = spawn('timeout', ['--kill-after=5s', '90s', '/usr/bin/python3', fileURLToPath(new URL('./parked-files-appliance.py', import.meta.url)), image], {
      detached: true, stdio: ['pipe', 'pipe', 'pipe'],
      env: { ...process.env, LIBGUESTFS_BACKEND: 'direct' },
    })
    this.child.stdout.setEncoding('utf8')
    this.child.stdout.on('data', (chunk: string) => this.receive(chunk))
    this.child.stdin.on('error', error => this.fail(error))
    // Guest errors may contain names/content. Drain without logging it.
    this.child.stderr.resume()
    this.child.once('error', error => this.fail(error))
    this.exited = new Promise(resolve => this.child.once('close', () => { this.fail(new Error('Parked appliance closed')); resolve() }))
  }

  private fail(error: Error): void {
    this.failure ??= error
    this.pending?.reject(error)
    this.pending = undefined
  }

  private receive(chunk: string): void {
    this.buffer += chunk
    if (this.buffer.length > 2 * 1024 * 1024) { this.fail(new Error('Appliance frame exceeds limit')); this.stop(); return }
    let end: number
    while ((end = this.buffer.indexOf('\n')) >= 0) {
      const line = this.buffer.slice(0, end); this.buffer = this.buffer.slice(end + 1)
      const pending = this.pending
      try {
        const value: unknown = JSON.parse(line)
        if (!pending || !value || typeof value !== 'object' || Array.isArray(value)) throw new Error('Unexpected appliance frame')
        const v = value as Record<string, unknown>
        if (pending.id === undefined) {
          if (Object.keys(v).join(',') !== 'ready' || v.ready !== true) throw new Error('Invalid appliance readiness')
        } else if (Object.keys(v).sort().join(',') !== 'id,result' || v.id !== pending.id || typeof v.result !== 'string') throw new Error('Invalid appliance response')
        this.pending = undefined
        pending.resolve(typeof v.result === 'string' ? v.result : '')
      } catch (error) { this.fail(error instanceof Error ? error : new Error('Invalid appliance response')); this.stop() }
    }
  }

  async call(command: string, args: string[]): Promise<string> {
    await this.ready
    if (this.failure) throw this.failure
    if (this.pending) throw new Error('Concurrent appliance request')
    const id = ++this.sequence
    return new Promise((resolve, reject) => {
      this.pending = { id, resolve, reject }
      this.child.stdin.write(JSON.stringify({ id, command, args }) + '\n', error => { if (error) this.fail(error) })
    })
  }

  stop(): void {
    if (this.child.pid && this.child.exitCode === null && this.child.signalCode === null) {
      try { process.kill(-this.child.pid, 'SIGTERM') } catch { /* Process already exited. */ }
    }
  }

  async close(): Promise<void> {
    this.child.stdin.end()
    const stop = setTimeout(() => this.stop(), 2000)
    const force = setTimeout(() => {
      if (this.child.pid && this.child.exitCode === null && this.child.signalCode === null) {
        try { process.kill(-this.child.pid, 'SIGKILL') } catch { /* Process already exited. */ }
      }
    }, 7000)
    try { await this.exited } finally { clearTimeout(stop); clearTimeout(force) }
  }
}
