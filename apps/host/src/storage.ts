import { recoveryRoute } from './recovery.js'
import { spawn, spawnSync } from 'node:child_process'
import { readFile } from 'node:fs/promises'
import { isAbsolute, join } from 'node:path'
import { ComputerBackups, type BackupHost, type RestoreContext } from './backup.js'
import type { Config } from './config.js'
import { DedupeHelper } from './disk-helper.js'
import type { ComputerLifecycle } from './lifecycle.js'
import type { Controller, Principal } from './server.js'
import { SharedStorage, type SharedStorageStatus } from './shared-storage.js'
import type { SystemImageBinding } from './system-image.js'
import { vmPaths } from './vm-paths.js'
import type { IncomingMessage, ServerResponse } from 'node:http'

/**
 * The host's storage features for microVM computers: shared storage (CABOOSE_SHARED_STORAGE)
 * and phone backups. Both use `caboose-disk` (CABOOSE_DISK_HELPER, default on PATH).
 */

/** One computer's part: attached to its lifecycle once the runtime exists. */
export interface ComputerStorage {
  attach(lifecycle: ComputerLifecycle<unknown>): void
  backups(request: IncomingMessage, response: ServerResponse, path: string, principal: Principal, context: RestoreContext): Promise<void>
  close(): void
  /** After the computer's disk is deleted. */
  destroy(): Promise<void>
}

export interface HostStorage {
  sharedStorage(): SharedStorageStatus | null
  forComputer(id: string, controller: Controller, phoneName: (phoneId: string) => string | undefined): ComputerStorage | undefined
  close(): Promise<void>
}

const HASH = /^[a-f0-9]{64}$/

async function readBinding(path: string): Promise<SystemImageBinding | null> {
  let value: SystemImageBinding
  try { value = JSON.parse(await readFile(path, 'utf8')) as SystemImageBinding } catch (error) {
    if ((error as NodeJS.ErrnoException).code === 'ENOENT') return null
    throw error
  }
  if (value?.version !== 1 || typeof value.directory !== 'string' || !isAbsolute(value.directory) || !value.hashes || (['base.raw', 'vmlinux', 'initrd', 'system.erofs'] as const).some(file => !HASH.test(value.hashes[file]))) throw new Error('Invalid saved system image binding')
  return value
}

function toggle(value: string | undefined, name: string): boolean {
  if (value === undefined || value === 'off') return false
  if (value === 'on') return true
  throw new Error(`${name} must be on or off`)
}

export function openStorage(deployment: Config, env: NodeJS.ProcessEnv): Promise<HostStorage> {
  const helper = env.CABOOSE_DISK_HELPER || 'caboose-disk'
  const shared = toggle(env.CABOOSE_SHARED_STORAGE, 'CABOOSE_SHARED_STORAGE')
  const delayMs = env.CABOOSE_SHARED_STORAGE_DELAY_MS === undefined ? 30 * 60_000 : Number(env.CABOOSE_SHARED_STORAGE_DELAY_MS)
  if (!Number.isSafeInteger(delayMs) || delayMs < 1000 || delayMs > 2_147_483_647) throw new Error('CABOOSE_SHARED_STORAGE_DELAY_MS must be an integer from 1000 to 2147483647')
  const linuxVm = process.platform === 'linux' && deployment.runtime === 'microvm'
  const installed = linuxVm && spawnSync(helper, ['--version'], { stdio: 'ignore' }).status === 0
  if (shared && !linuxVm) throw new Error('CABOOSE_SHARED_STORAGE requires a Linux microVM host')
  if (shared && !installed) throw new Error(`CABOOSE_SHARED_STORAGE requires caboose-disk (${helper} was not found)`)
  const unavailable = !linuxVm ? 'Phone backups need a Linux microVM host'
    : !installed ? 'Phone backups need caboose-disk on the host'
    : !deployment.parkedFiles ? 'Phone backups need parked Files (CABOOSE_PARKED_FILES=on)'
    : null
  const root = deployment.imageRoot
  const backupHost: BackupHost = { helper, imageRoot: root, cacheDirectory: join(root, 'disk-cache'), unavailable, ...(env.CABOOSE_SPLIT_IMAGE ? { splitImage: env.CABOOSE_SPLIT_IMAGE } : {}) }
  const dedupe = shared ? new DedupeHelper(helper, join(root, 'shared-storage')) : undefined
  const storage = dedupe ? new SharedStorage(dedupe, {
    statePath: join(root, 'shared-storage.json'),
    delayMs,
    // Return freed blocks to the device below (a sparse XFS image, or an SSD).
    trim: () => new Promise((resolve, reject) => {
      const child = spawn('fstrim', [root], { stdio: 'ignore' })
      child.once('error', reject)
      child.once('close', code => code === 0 ? resolve() : reject(new Error(`fstrim exited with ${code}`)))
    }),
  }) : undefined
  return (storage?.open() ?? Promise.resolve()).then(() => ({
    sharedStorage: () => storage?.status() ?? null,
    forComputer(id, controller, phoneName) {
      if (deployment.runtime !== 'microvm') return undefined
      const paths = () => vmPaths(root, id, deployment.vmTemplate)
      const binding = () => readBinding(join(root, 'overlays', `${id}.system-image.json`))
      let backups: ComputerBackups | undefined
      return {
        attach(lifecycle) {
          backups = new ComputerBackups(backupHost, { id, lifecycle, directory: paths().directory, parkedView: async () => controller.parkedFilesView?.(), binding, phoneName })
          void backups.open().catch(error => console.error(`Backups of ${id} could not start:`, error))
          storage?.attach({
            id, lifecycle,
            base: async () => {
              const bound = await binding()
              return bound ? join(bound.directory, 'base.raw') : join(root, 'base.raw')
            },
            files: async () => {
              const view = await controller.parkedFilesView?.()
              return { disk: paths().disk, clones: [...(view ? [view.image] : []), ...await backups!.captureFiles()] }
            },
          })
        },
        backups: (request, response, path, principal, context) => {
          if (!backups) throw new Error('Backups are not attached')
          if (path === '/v1/recovery' || path.startsWith('/v1/recovery/')) return recoveryRoute(backups, request, response, path, principal, context)
          return backups.handle(request, response, path, principal, context)
        },
        close: () => backups?.close(),
        async destroy() {
          await backups?.destroy()
          await storage?.forget(id)
        },
      }
    },
    async close() {
      await storage?.close()
      await dedupe?.close()
    },
  }))
}
