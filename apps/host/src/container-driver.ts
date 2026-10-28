import { execFile } from 'node:child_process'
import { randomBytes } from 'node:crypto'
import { existsSync } from 'node:fs'
import { readFile } from 'node:fs/promises'
import type { Config, GpuKind } from './config.js'
import type { App, Controller, Session } from './server.js'

/**
 * The computer as a container instead of a microVM, for hosts whose GPU a container can use
 * but a VM cannot have: WSL2's paravirtual /dev/dxg (any vendor), a Linux NVIDIA GPU through
 * the container toolkit, or Linux render nodes (Intel, AMD). The image reads CABOOSE_GPU to
 * pick its GL driver and Xpra's video encoder; with no GPU it runs on the CPU.
 *
 * The image provides `caboose-session start | start-agent | ready <display>`, which runs
 * D-Bus, PulseAudio and the Xpra displays as `caboose`, reading the per-wake token from
 * /run/caboose/xpra-token. Displays are published on loopback only.
 *
 * Parking freezes the container (cgroup freezer): memory stays in RAM and resume is
 * instant, but unlike a microVM snapshot it does not survive a restart of the host;
 * after one the computer boots fresh with its home intact. See docs/architecture.md.
 */
export type Docker = (args: string[], timeoutMs?: number) => Promise<string>

export function dockerCli(binary = 'docker'): Docker {
  return (args, timeoutMs = 60_000) => new Promise((resolve, reject) => {
    execFile(binary, args, { timeout: timeoutMs, maxBuffer: 64 * 1024 * 1024 }, (error, stdout, stderr) => {
      if (error) reject(new Error(`docker ${args[0]} failed: ${(stderr || error.message).trim()}`))
      else resolve(stdout)
    })
  })
}

/** The GPU this host can give a container, by the devices it has. */
export function detectGpu(exists: (path: string) => boolean = existsSync): GpuKind {
  if (exists('/dev/dxg')) return 'wsl'
  if (exists('/dev/nvidiactl') || exists('/dev/nvidia0')) return 'nvidia'
  if (exists('/dev/dri/renderD128')) return 'dri'
  return 'none'
}

/** `docker run` arguments that hand the container the GPU. */
export function gpuArgs(kind: GpuKind): string[] {
  switch (kind) {
    case 'wsl': return ['--device', '/dev/dxg', '-v', '/usr/lib/wsl:/usr/lib/wsl:ro', '-e', 'LD_LIBRARY_PATH=/usr/lib/wsl/lib', '-e', 'CABOOSE_GPU=wsl']
    case 'nvidia': return ['--gpus', 'all', '-e', 'NVIDIA_DRIVER_CAPABILITIES=all', '-e', 'CABOOSE_GPU=nvidia']
    case 'dri': return ['--device', '/dev/dri', '-e', 'CABOOSE_GPU=dri']
    case 'none': return ['-e', 'CABOOSE_GPU=none']
  }
}

export function createContainerController(config: Config, dependencies: { docker?: Docker; exists?: (path: string) => boolean } = {}): Controller {
  const docker = dependencies.docker ?? dockerCli()
  const name = config.containerName
  const gpu: GpuKind = config.gpu === 'auto' ? detectGpu(dependencies.exists) : config.gpu
  let displayToken = ''
  let running = false

  async function state(): Promise<'missing' | 'running' | 'paused' | 'stopped'> {
    try {
      const status = (await docker(['inspect', '-f', '{{.State.Status}}', name], 15_000)).trim()
      if (status === 'running') return 'running'
      if (status === 'paused') return 'paused'
      return 'stopped'
    } catch {
      return 'missing'
    }
  }

  function runArgs(): string[] {
    return [
      'run', '-d', '--name', name, '--hostname', 'caboose', '--init',
      '--restart', 'no',
      '--memory', `${config.memoryMb}m`, '--cpus', String(config.vcpus), '--shm-size', '2g',
      '-p', '127.0.0.1:14500:14500', '-p', '127.0.0.1:14501:14501',
      '-v', `${config.containerHome}:/home/caboose`,
      ...gpuArgs(gpu),
      ...config.containerArgs,
      config.containerImage,
    ]
  }

  async function exec(user: 'root' | 'caboose', command: string, args: string[], timeoutMs = 30_000): Promise<string> {
    if (!running) throw new Error('Computer is not running')
    return docker(['exec', '-u', user, name, command, ...args], timeoutMs)
  }

  async function guestApps(action: string, id?: string): Promise<string> {
    const script = await readFile(new URL('./guest-apps.py', import.meta.url), 'utf8')
    return exec('caboose', '/usr/bin/env', ['DISPLAY=:100', 'HOME=/home/caboose', '/usr/bin/python3', '-c', script, action, ...(id ? [id] : [])], 60_000)
  }

  return {
    displayUrl: 'ws://127.0.0.1:14500/',
    agentDisplayUrl: 'ws://127.0.0.1:14501/',
    async ensureAgentSeat() {
      await exec('root', '/usr/local/bin/caboose-session', ['start-agent'], 120_000)
    },
    guest() {
      if (!running) return undefined
      return { run: (command: string, args: string[], timeoutMs?: number) => exec('root', command, args, timeoutMs) }
    },
    stats: () => ({ host: 'caboose-host', runtime: 'container', gpu, container: name, running }),
    async wake(): Promise<Session> {
      const current = await state()
      if (current === 'missing') await docker(runArgs(), 300_000)
      else if (current === 'stopped') await docker(['start', name], 120_000)
      else if (current === 'paused') await docker(['unpause', name], 60_000)
      running = true
      try {
        if (!displayToken) {
          displayToken = randomBytes(32).toString('hex')
          // Xpra reads the password file on each connection; never put a newline in it.
          await exec('root', '/bin/sh', ['-c', 'install -d -m 0755 /run/caboose; printf %s "$1" > /run/caboose/xpra-token; chown caboose:caboose /run/caboose/xpra-token; chmod 0600 /run/caboose/xpra-token', 'sh', displayToken])
        }
        await exec('root', '/usr/local/bin/caboose-session', ['start'], 240_000)
        await exec('root', '/usr/local/bin/caboose-session', ['ready', ':100'], 240_000)
        return { state: 'running', display: { path: '/v1/display', token: displayToken, protocol: 'xpra-ws' }, computer: { name: 'Caboose', image: gpu === 'none' ? 'Debian 13' : 'Debian 13 · GPU', memoryMb: config.memoryMb, vcpus: config.vcpus } }
      } catch (error) {
        running = false
        throw error
      }
    },
    async park() {
      if ((await state()) === 'running') await docker(['pause', name], 60_000)
      running = false
    },
    async apps(): Promise<App[]> {
      const apps: App[] = []
      for (;;) {
        const page = JSON.parse(await guestApps('list', String(apps.length))) as App[]
        apps.push(...page)
        if (page.length < 10) return apps
      }
    },
    async launch(id: string): Promise<void> { await guestApps('launch', id) },
  }
}
