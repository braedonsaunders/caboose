import { spawn } from 'node:child_process'
import { createInterface } from 'node:readline'

// One request at a time. A lost response is never replayed: an input may already have run.
export class Worker {
  child
  pending
  signature
  constructor(script, args = [], timeout = 60_000) { this.script = script; this.args = args; this.timeout = timeout }
  close(error = new Error('helper stopped')) {
    const child = this.child
    this.child = undefined
    if (this.pending) { this.pending.reject(error); this.pending = undefined }
    if (child?.pid) {
      try { process.kill(-child.pid, 'SIGKILL') } catch { child.kill('SIGKILL') }
    }
  }
  async request(request, env) {
    const signature = JSON.stringify(env)
    if (this.child && signature !== this.signature) this.close()
    if (!this.child) {
      this.signature = signature
      const child = this.child = spawn('python3', [this.script, 'serve', ...this.args], { env, detached: true, stdio: ['pipe', 'pipe', 'ignore'] })
      const lines = createInterface({ input: child.stdout })
      lines.on('line', line => {
        if (child !== this.child || !this.pending) return
        const pending = this.pending; this.pending = undefined
        try { pending.resolve(JSON.parse(line)) } catch { pending.reject(new Error('invalid helper response')); this.close() }
      })
      const stopped = error => { if (child === this.child) this.close(error) }
      child.on('error', stopped)
      child.on('exit', () => stopped(new Error('helper exited; retry the tool')))
      child.stdin.on('error', stopped)
    }
    if (this.pending) throw new Error('helper already busy')
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => this.close(new Error('helper timed out; action outcome is unknown')), this.timeout)
      this.pending = { resolve: value => { clearTimeout(timer); resolve(value) }, reject: error => { clearTimeout(timer); reject(error) } }
      this.child.stdin.write(JSON.stringify(request) + '\n')
    })
  }
}
