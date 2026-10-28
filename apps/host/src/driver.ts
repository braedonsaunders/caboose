import { createHash, randomBytes } from 'node:crypto'
import { constants, existsSync, lstatSync, mkdirSync, readFileSync } from 'node:fs'
import { access, mkdir, readFile, rm } from 'node:fs/promises'
import { join } from 'node:path'
import { createDeskHost, createCloudHypervisorBackend, createVirtualizationBackend, listenDeskPort, type DeskHandle, type DeskBackend, type DeskHost, type DeskHostOptions } from '@braedonsaunders/appkit-desk'
import type { Config } from './config.js'
import { AGENT_DISPLAY_PORT, DISPLAY_ENV_PATH, OWNER_DISPLAY_PORT, WRITE_TOKEN_SCRIPT, parseEnvFile } from './display.js'
import { TERMINAL_PORT } from './terminal.js'
import { configureGuest, ensureNetwork, networkSlot, removeNetwork } from './network.js'
import type { App, Controller, Session } from './server.js'
import { writePrivateJson, type ComputerSettings } from './settings.js'

export interface ComputerResources { memoryMb: number; vcpus: number }

/** Which computer a controller drives: its id names its disk, and its slot its network. */
export interface ComputerIdentity { id: string; slot: number }

const OWNER: ComputerIdentity = { id: 'owner', slot: 0 }
const APPKIT_LEASE_MS = 90_000
/** Snapshots record the host CPU they were taken on; tests off Linux supply the signature. */
type SnapshotSignature = Pick<DeskHostOptions, 'cpuSignature' | 'readSnapshotSignature' | 'writeSnapshotSignature'>
type DeskPoolDependencies = { backend?: DeskBackend; deviceExists?: (path: string) => boolean; snapshotSignature?: SnapshotSignature }

function usesVirtualization(dependencies: DeskPoolDependencies): boolean {
  return dependencies.backend ? dependencies.backend.hypervisor === 'virtualization' : process.platform === 'darwin'
}

/** macOS Unix socket paths are limited to 103 bytes; the image root can be much longer. */
function macRuntimeDirectory(imageRoot: string): string {
  const uid = process.getuid!()
  const parent = `/tmp/caboose-${uid}`
  const directory = join(parent, createHash('sha256').update(imageRoot).digest('hex').slice(0, 16))
  for (const path of [parent, directory]) {
    try { mkdirSync(path, { mode: 0o700 }) } catch (error) {
      if ((error as NodeJS.ErrnoException).code !== 'EEXIST') throw error
    }
    const stat = lstatSync(path)
    if (!stat.isDirectory() || stat.uid !== uid || (stat.mode & 0o077)) {
      throw new Error(`Caboose requires a private runtime directory owned by this user: ${path}`)
    }
  }
  return directory
}

/**
 * One appkit-desk host for every microVM computer, so they share its capacity (starts beyond
 * it queue), vsock CIDs and idle sweeps.
 */
export function createDeskPool(config: Config, dependencies: DeskPoolDependencies = {}): DeskHost {
  const nativeMac = usesVirtualization(dependencies)
  const backend = dependencies.backend ?? (nativeMac
    ? createVirtualizationBackend({ helperPath: config.vmmPath, connectTimeoutMs: 120_000 })
    : createCloudHypervisorBackend({ connectTimeoutMs: 120_000 }))
  return createDeskHost({
    imageRoot: config.imageRoot, vmmPath: config.vmmPath,
    // Images may be downloaded after pool creation; don't let AppKit's eager existence
    // check permanently omit the initramfs on a fresh installation.
    initramfsPath: join(config.imageRoot, 'initrd'),
    // No console=ttyS0: appkit-desk launches with --serial off, and a kernel told to use a
    // serial console that does not exist can hang before userspace.
    kernelCmdline: `root=/dev/vda3 rw${nativeMac ? ' console=hvc0' : ''}`,
    runtimeDir: nativeMac ? macRuntimeDirectory(config.imageRoot) : join(config.imageRoot, 'runtime'), backend,
    ...(nativeMac ? { guestNetwork: { guestAddress: '10.0.2.15', gatewayAddress: '10.0.2.2', prefixLength: 24, allowLan: false } } : {}),
    ...(dependencies.deviceExists ? { deviceExists: dependencies.deviceExists } : {}),
    ...dependencies.snapshotSignature,
    parkWithMemory: true, idleSuspendMs: APPKIT_LEASE_MS, defaultLeaseMs: APPKIT_LEASE_MS, capacity: config.maxRunning,
    ports: { onEvent: () => {}, audit: () => {} },
  })
}

export function createController(config: Config, dependencies: DeskPoolDependencies & {
  identity?: ComputerIdentity
  /** The shared desk host; a controller made without one gets its own (tests, a single computer). */
  desks?: DeskHost
  network?: () => Promise<void>
  removeNetwork?: () => Promise<void>
  settings?: () => ComputerSettings
} = {}): Controller {
  const nativeMac = usesVirtualization(dependencies)
  const { id, slot } = dependencies.identity ?? OWNER
  const address = networkSlot(slot)
  const host = dependencies.desks ?? createDeskPool(config, dependencies)
  let desk: DeskHandle | undefined
  let heartbeat: ReturnType<typeof setInterval> | undefined
  const relays = new Map<number, Awaited<ReturnType<typeof listenDeskPort>>>()
  async function closeRelays(): Promise<void> {
    const open = [...relays.values()]
    relays.clear()
    await Promise.all(open.map(relay => relay.close()))
  }
  function endpoint(port: number, scheme: 'http' | 'ws'): string {
    if (!nativeMac) return `${scheme}://${address.guest}:${port}${scheme === 'ws' ? '/' : ''}`
    const relay = relays.get(port)
    if (!relay) throw new Error('Computer is not running')
    return `${scheme}://${relay.host}:${relay.port}${scheme === 'ws' ? '/' : ''}`
  }
  let displayToken = ''
  let restartWarning: string | null = null
  const overlayPath = join(config.imageRoot, 'overlays', `${id}.raw`)
  const snapshotPath = join(config.imageRoot, 'overlays', `${id}.snapshot`)
  const resourcesPath = join(config.imageRoot, 'overlays', `${id}.resources.json`)
  let resources: ComputerResources | null = null
  try {
    const saved = JSON.parse(readFileSync(resourcesPath, 'utf8')) as ComputerResources
    if (!saved || !Number.isSafeInteger(saved.memoryMb) || saved.memoryMb < 1 || !Number.isSafeInteger(saved.vcpus) || saved.vcpus < 1) {
      throw new Error('Invalid saved computer resources')
    }
    resources = { memoryMb: saved.memoryMb, vcpus: saved.vcpus }
  } catch (error) {
    if ((error as NodeJS.ErrnoException).code !== 'ENOENT') throw error
  }
  /** What an app launched onto the owner's display needs; caboose-display's, read at each wake. */
  let launchEnv: string[] = []
  const settings = (): ComputerSettings => dependencies.settings?.() ?? { name: 'Caboose', memoryMb: config.memoryMb, vcpus: config.vcpus, idleMs: config.idleMs, defaultAgent: null }
  function clearHeartbeat(): void {
    if (heartbeat) clearInterval(heartbeat)
    heartbeat = undefined
  }
  async function command(command: string, args: string[], timeoutMs = 30_000): Promise<string> {
    if (!desk) throw new Error('Computer is not running')
    const result = await desk.exec({ command, args, timeoutMs })
    if (result.exitCode !== 0 || result.truncated) throw new Error(`Guest command failed: ${result.stderr || result.exitCode}`)
    return result.stdout
  }
  async function guestApps(action: string, id?: string, path?: string): Promise<string> {
    const script = await readFile(new URL('./guest-apps.py', import.meta.url), 'utf8')
    return command('/usr/sbin/runuser', ['-u', 'caboose', '--', '/usr/bin/env', ...launchEnv, '/usr/bin/python3', '-c', script, action, ...(id ? [id] : []), ...(path ? [path] : [])], 60_000)
  }
  /** A caboose-display instance is ready once it answers a hello carrying this wake's token (the image's probe). */
  async function startDisplay(service: string, port: number): Promise<void> {
    await command('/bin/sh', ['-c', 'systemctl start "$1" && caboose-display-ready 60 "$2"', 'sh', service, String(port)], 240_000)
  }
  const controller: Controller = {
    componentsMode: 'vm',
    get displayUrl() { return endpoint(OWNER_DISPLAY_PORT, 'ws') },
    get agentDisplayUrl() { return endpoint(AGENT_DISPLAY_PORT, 'ws') },
    fileService: () => ({ url: endpoint(14700, 'http'), token: displayToken }),
    terminalService: () => ({ url: endpoint(TERMINAL_PORT, 'http'), token: displayToken }),
    async ensureAgentSeat() {
      // Same per-wake token and user as the owner's display; started only when wanted.
      await startDisplay('caboose-display-agent.service', AGENT_DISPLAY_PORT)
    },
    guest() {
      if (!desk) return undefined
      return { run: (cmd: string, args: string[], timeoutMs?: number) => command(cmd, args, timeoutMs), ownerEnv: launchEnv }
    },
    stats: () => ({ host: 'caboose-host', hypervisor: nativeMac ? 'virtualization' : 'cloud-hypervisor', kvm: existsSync('/dev/kvm'), desk: host.stats() }),
    activeResources: () => desk || existsSync(snapshotPath) ? resources : null,
    hasSavedState: () => Boolean(desk) || existsSync(snapshotPath),
    lastError: () => restartWarning,
    async wake(): Promise<Session> {
      const desired = settings()
      await Promise.all([
        ...(nativeMac || dependencies.deviceExists ? [] : [access('/dev/kvm', constants.R_OK | constants.W_OK)]),
        access(config.vmmPath, constants.X_OK),
        ...['base.raw', 'vmlinux', 'initrd'].map(file => access(join(config.imageRoot, file), constants.R_OK)),
      ])
      await mkdir(join(config.imageRoot, 'overlays'), { recursive: true })
      await mkdir(join(config.imageRoot, 'runtime'), { recursive: true })
      if (!nativeMac) await (dependencies.network ?? (() => ensureNetwork(slot)))()
      const restoring = existsSync(snapshotPath)
      const wasResident = Boolean(desk)
      desk = await host.start({ deskId: id, baseImage: join(config.imageRoot, 'base.raw'), overlayPath, memoryMb: desired.memoryMb, vcpus: desired.vcpus, leaseMs: APPKIT_LEASE_MS, ...(nativeMac ? {} : { network: { tapDevice: address.tap } }) })
      try {
        if (restoring && host.stats().lastError?.includes('could not resume from its snapshot')) {
          throw new Error(host.stats().lastError ?? 'Snapshot restore failed')
        }
        if (!restoring && !wasResident) {
          resources = { memoryMb: desired.memoryMb, vcpus: desired.vcpus }
          await writePrivateJson(resourcesPath, resources)
        }
        await configureGuest(desk, slot, nativeMac ? { host: '10.0.2.2', guest: '10.0.2.15', prefix: 24 } : undefined)
        if (nativeMac && !relays.size) {
          for (const port of [OWNER_DISPLAY_PORT, AGENT_DISPLAY_PORT, 14700, TERMINAL_PORT]) {
            relays.set(port, await listenDeskPort(desk, port))
          }
        }
        displayToken = randomBytes(32).toString('hex')
        await command('/bin/sh', ['-c', WRITE_TOKEN_SCRIPT, 'sh', displayToken])
        await startDisplay('caboose-display.service', OWNER_DISPLAY_PORT)
        launchEnv = parseEnvFile(await command('/bin/cat', [DISPLAY_ENV_PATH]))
        if (!launchEnv.length) throw new Error(`caboose-display wrote no launch environment to ${DISPLAY_ENV_PATH}`)
        clearHeartbeat()
        heartbeat = setInterval(() => {
          try { desk?.renewLease(APPKIT_LEASE_MS) } catch (error) { console.error('Desk lease renewal failed:', error) }
        }, 20_000)
        heartbeat.unref()
        return { state: 'running', display: { path: '/v1/display', token: displayToken, protocol: 'caboose-display' }, computer: { name: settings().name, image: 'Debian 13', ...(resources ?? { memoryMb: config.memoryMb, vcpus: config.vcpus }) } }
      } catch (error) {
        clearHeartbeat()
        await closeRelays().catch(failure => console.error('Failed to close guest relays:', failure))
        await host.suspend(id).catch(failure => console.error('Failed to park after wake error:', failure))
        desk = undefined
        throw error
      }
    },
    async park() {
      clearHeartbeat()
      await closeRelays()
      await host.suspend(id)
      desk = undefined
      displayToken = ''
      if (!existsSync(snapshotPath)) {
        throw new Error(host.stats().lastError ?? 'Memory snapshot was not created')
      }
    },
    async restart() {
      restartWarning = null
      // A wedged guest still needs a restart. Try to flush briefly, then surface the
      // failure while proceeding with the explicitly confirmed cold restart.
      if (desk) {
        try { await command('/bin/sync', [], 5_000) }
        catch (error) {
          restartWarning = `The computer restarted without confirming a disk flush: ${error instanceof Error ? error.message : String(error)}`
          console.error(restartWarning)
        }
      }
      clearHeartbeat()
      // Stops a running computer without writing a memory image and drops a parked one's
      // snapshot; the disk is kept. Never destroy() here: it deletes the disk, which only
      // deleting the computer may do.
      await closeRelays()
      await host.shutdown(id)
      desk = undefined
      displayToken = ''
      // A computer parked before this host process started is unknown to appkit-desk,
      // so its snapshot is removed here too.
      await rm(snapshotPath, { recursive: true, force: true })
      resources = null
      return controller.wake()
    },
    /** Deletes the computer: its memory, snapshot and disk, and its network. Nothing of it is kept. */
    async destroy() {
      clearHeartbeat()
      await closeRelays()
      await host.destroy(id).catch(error => console.error(`Desk ${id} could not be destroyed cleanly:`, error))
      desk = undefined
      displayToken = ''
      resources = null
      // A computer parked before this host process started is unknown to appkit-desk.
      await rm(snapshotPath, { recursive: true, force: true })
      await rm(overlayPath, { force: true })
      await rm(resourcesPath, { force: true })
      if (!nativeMac) await (dependencies.removeNetwork ?? (() => removeNetwork(slot)))()
    },
    async apps(): Promise<App[]> {
      const apps: App[] = []
      for (;;) {
        const page = JSON.parse(await guestApps('list', String(apps.length))) as App[]
        apps.push(...page)
        if (page.length < 10) return apps
      }
    },
    async launch(id: string, path?: string): Promise<void> { await guestApps('launch', id, path) },
  }
  return controller
}
