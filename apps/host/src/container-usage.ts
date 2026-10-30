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

/** A killable worker makes the deadline apply even during a slow filesystem call. */
export async function allocatedVolume(path: string, entryLimit = 100_000): Promise<ComputerStorage['home']> {
  const script = `
    const fs = await import('node:fs/promises');
    const root = process.argv[1], seen = new Set(); let left = Number(process.argv[2]), logical = 0, allocated = 0;
    if (!(await fs.lstat(root)).isDirectory()) throw Error('Not a directory');
    async function walk(path, depth = 0) {
      if (--left < 0 || depth > 32) throw Error('Scan limit');
      const s = await fs.lstat(path), key = s.dev + ':' + s.ino;
      if (seen.has(key)) return; seen.add(key);
      if (s.isDirectory()) { const dir = await fs.opendir(path); for await (const item of dir) await walk(path + '/' + item.name, depth + 1); }
      else if (s.isFile() || s.isSymbolicLink()) { logical += s.size; allocated += s.blocks * 512; }
      else throw Error('Unsupported entry');
    }
    await walk(root); process.stdout.write(JSON.stringify({logical, allocated}));
  `
  const { stdout } = await promisify(execFile)(process.execPath, ['--input-type=module', '-e', script, path, String(entryLimit)], { timeout: 2000, killSignal: 'SIGKILL', maxBuffer: 4096 })
  const result = JSON.parse(stdout)
  return { logicalBytes: measured(result.logical), allocatedBytes: measured(result.allocated) }
}
