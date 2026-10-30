import { request } from 'node:http'
import { execFile } from 'node:child_process'
import { promisify } from 'node:util'
import type { UsageCounters, ComputerStorage } from '../../../packages/capacity/types.js'
import { measured, unavailable } from './capacity.js'

/** Docker Engine local socket only. Absolute deadline and response-size cap include a stalled daemon. */
export function engineJson(socketPath: string, path: string): Promise<any> {
  return new Promise((resolve, reject) => {
    const req = request({ socketPath, path, method: 'GET' }, response => {
      let body = ''
      response.on('data', chunk => { body += chunk; if (body.length > 2 * 1024 * 1024) req.destroy(new Error('Runtime response too large')) })
      response.on('error', reject)
      response.on('end', () => { try { if (response.statusCode !== 200) throw new Error('Runtime counters unavailable'); resolve(JSON.parse(body)) } catch (e) { reject(e) } })
    })
    const timer = setTimeout(() => req.destroy(new Error('Runtime counter timeout')), 4000)
    req.on('close', () => clearTimeout(timer)); req.on('error', reject); req.end()
  })
}
export function dockerCounters(info: any, stats: any, at = Date.now()): UsageCounters {
  const cpu = stats.cpu_stats?.cpu_usage?.total_usage, memory = stats.memory_stats?.usage
  const cpus = info.HostConfig?.NanoCpus / 1e9
  if (typeof info.Id !== 'string' || typeof info.State?.StartedAt !== 'string' || stats.id !== info.Id || !info.State?.Running || ![cpu, memory, cpus].every(n => Number.isFinite(n) && n >= 0) || cpus <= 0) throw new Error('Incomplete runtime counters')
  const cache = stats.memory_stats.stats?.inactive_file ?? stats.memory_stats.stats?.total_inactive_file
  return { identity: `${info.Id}:${info.State.StartedAt}`, at, cpuSeconds: cpu / 1e9, vcpus: cpus,
    memoryBytes: memory, cacheBytes: Number.isFinite(cache) && cache >= 0 ? cache : null,
    memoryLimitBytes: info.HostConfig.Memory > 0 ? info.HostConfig.Memory : null, memoryKind: 'cgroup' }
}
let storageBusy = false
export function containerUsage(name: string, home: string, socket: () => Promise<string>) {
  let storage: Promise<ComputerStorage> | undefined, storageAt = 0
  const info = async (size = false) => engineJson(await socket(), `/containers/${encodeURIComponent(name)}/json${size ? '?size=true' : ''}`)
  return {
    async counters() {
      const container = await info()
      if (!container.State?.Running) throw new Error('Container is not running')
      const stats = await engineJson(await socket(), `/containers/${encodeURIComponent(container.Id)}/stats?stream=false&one-shot=true`)
      const at = Date.parse(stats.read)
      if (!Number.isFinite(at) || Math.abs(Date.now() - at) > 15_000) throw new Error('Stale runtime sample')
      return dockerCounters(container, stats, at)
    },
    storage(): Promise<ComputerStorage> {
      if (storage && Date.now() - storageAt < 15 * 60_000) return storage
      if (storageBusy) return Promise.reject(new Error('Another storage measurement is in progress'))
      storageBusy = true
      storageAt = Date.now()
      storage = (async () => {
        const unknown = unavailable('Home volume is not locally accessible or scan is incomplete')
        let homeUsage = { logicalBytes: unknown, allocatedBytes: unknown }
        const container = await info(true)
        const mount = container.Mounts?.find((m: any) => m.Type === 'volume' && m.Name === home && m.Destination === '/home/caboose')
        if (mount && typeof mount.Source === 'string') {
          try { homeUsage = await allocatedVolume(mount.Source) } catch {}
        }
        return { sampledAt: Date.now(), home: homeUsage,
          writableLayerLogicalBytes: typeof container.SizeRw === 'number' ? measured(container.SizeRw) : unavailable('Docker writable layer size unavailable'),
          sharedImageLogicalBytes: typeof container.SizeRootFs === 'number' && typeof container.SizeRw === 'number' ? measured(container.SizeRootFs - container.SizeRw) : unavailable('Shared image size unavailable') }
      })().catch(() => ({ sampledAt: Date.now(), home: { logicalBytes: unavailable('Storage collection failed'), allocatedBytes: unavailable('Storage collection failed') }, writableLayerLogicalBytes: unavailable('Docker size request failed or timed out'), sharedImageLogicalBytes: unavailable('Docker size request failed or timed out') })).finally(() => { storageBusy = false })
      return storage
    },
  }
}

/** Descriptor-relative metadata traversal: a renamed directory cannot redirect a child lookup. */
export const VOLUME_SCAN_SCRIPT = `
import os, stat, sys, json
left = int(sys.argv[2]); logical = 0; allocated = 0; seen = set()
flags = os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW
root = os.open(sys.argv[1], flags)
root_device = os.fstat(root).st_dev

def walk(fd, depth=0):
    global left, logical, allocated
    if depth > 32: raise RuntimeError('Depth limit')
    with os.scandir(fd) as entries:
        for entry in entries:
            left -= 1
            if left < 0: raise RuntimeError('Entry limit')
            s = os.stat(entry.name, dir_fd=fd, follow_symlinks=False)
            if s.st_dev != root_device: raise RuntimeError('Mount boundary')
            key = (s.st_dev, s.st_ino)
            if key in seen: continue
            seen.add(key)
            if stat.S_ISDIR(s.st_mode):
                child = os.open(entry.name, flags, dir_fd=fd)
                try:
                    opened = os.fstat(child)
                    if (opened.st_dev, opened.st_ino) != key: raise RuntimeError('Directory changed')
                    walk(child, depth + 1)
                finally: os.close(child)
            elif stat.S_ISREG(s.st_mode) or stat.S_ISLNK(s.st_mode):
                logical += s.st_size; allocated += s.st_blocks * 512
            else: raise RuntimeError('Unsupported entry')
try:
    walk(root)
    print(json.dumps(dict(logical=logical, allocated=allocated)))
finally: os.close(root)
`
/** A killable worker makes the deadline apply even during a slow filesystem call. */
export async function allocatedVolume(path: string, entryLimit = 100_000): Promise<ComputerStorage['home']> {
  const { stdout } = await promisify(execFile)('python3', ['-I', '-c', VOLUME_SCAN_SCRIPT, path, String(entryLimit)], { timeout: 2000, killSignal: 'SIGKILL', maxBuffer: 4096 })
  const result = JSON.parse(stdout)
  return { logicalBytes: measured(result.logical), allocatedBytes: measured(result.allocated) }
}

/** Docker CLI environment precedence, shared with the telemetry endpoint selection. */
export function dockerEndpointSelection(env: NodeJS.ProcessEnv): { endpoint?: string; args: string[] } {
  if (env.DOCKER_CONTEXT) return { args: ['context', 'inspect', env.DOCKER_CONTEXT, '--format', '{{.Endpoints.docker.Host}}'] }
  if (env.DOCKER_HOST) return { endpoint: env.DOCKER_HOST, args: [] }
  return { args: ['context', 'inspect', '--format', '{{.Endpoints.docker.Host}}'] }
}
