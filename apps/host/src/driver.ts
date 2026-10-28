import { randomBytes } from 'node:crypto'
import { constants, existsSync, readFileSync } from 'node:fs'
import { access, mkdir, readFile, rm } from 'node:fs/promises'
import { join } from 'node:path'
import { createDeskHost, createCloudHypervisorBackend, type DeskHandle, type DeskBackend, type DeskHostOptions } from '@braedonsaunders/appkit-desk'
import type { Config } from './config.js'
import { OWNER_DISPLAYS } from './display.js'
import { configureGuest, ensureNetwork, GUEST_ADDRESS, TAP_DEVICE } from './network.js'
import type { App, Controller, Session } from './server.js'
import { writePrivateJson, type ComputerSettings } from './settings.js'

export interface ComputerResources { memoryMb: number; vcpus: number }

const COMPUTER_ID = 'owner'
const APPKIT_LEASE_MS = 90_000
/** Snapshots record the host CPU they were taken on; tests off Linux supply the signature. */
type SnapshotSignature = Pick<DeskHostOptions, 'cpuSignature' | 'readSnapshotSignature' | 'writeSnapshotSignature'>

export function createController(config: Config, dependencies: { backend?: DeskBackend; network?: () => Promise<void>; deviceExists?: (path: string) => boolean; settings?: () => ComputerSettings; snapshotSignature?: SnapshotSignature } = {}): Controller {
  const host = createDeskHost({
    imageRoot: config.imageRoot, vmmPath: config.vmmPath,
    // No console=ttyS0: appkit-desk launches with --serial off, and a kernel told to use a
    // serial console that does not exist can hang before userspace (the #18 image did, >160 s).
    kernelCmdline: 'root=/dev/vda3 rw',
    runtimeDir: join(config.imageRoot, 'runtime'), backend: dependencies.backend ?? createCloudHypervisorBackend({ connectTimeoutMs: 120_000 }),
    ...(dependencies.deviceExists ? { deviceExists: dependencies.deviceExists } : {}),
    ...dependencies.snapshotSignature,
    parkWithMemory: true, idleSuspendMs: APPKIT_LEASE_MS, defaultLeaseMs: APPKIT_LEASE_MS,
    ports: { onEvent: () => {}, audit: () => {} },
  })
  let desk: DeskHandle | undefined
  let heartbeat: ReturnType<typeof setInterval> | undefined
  let displayToken = ''
  let restartWarning: string | null = null
  const snapshotPath = join(config.imageRoot, 'overlays', `${COMPUTER_ID}.snapshot`)
  const resourcesPath = join(config.imageRoot, 'overlays', `${COMPUTER_ID}.resources.json`)
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
  const owner = OWNER_DISPLAYS[config.display]
  const settings = (): ComputerSettings => dependencies.settings?.() ?? { name: 'Caboose', memoryMb: config.memoryMb, vcpus: config.vcpus, idleMs: config.idleMs }
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
  async function guestApps(action: string, id?: string): Promise<string> {
    const script = await readFile(new URL('./guest-apps.py', import.meta.url), 'utf8')
    return command('/usr/sbin/runuser', ['-u', 'caboose', '--', '/usr/bin/env', ...owner.launchEnv, '/usr/bin/python3', '-c', script, action, ...(id ? [id] : [])], 60_000)
  }
  async function startDisplay(service: string, port: number): Promise<void> {
    // systemd and the listening socket can be ready before Xpra can serve a hello.
    await command('/bin/sh', ['-c', `systemctl start "$1"; for i in $(seq 1 60); do if systemctl is-active --quiet "$1" && ss -lnt | grep -Eq ":$2[[:space:]]" && timeout 3 runuser -u caboose -- xpra info "$3" >/dev/null 2>&1; then exit 0; fi; sleep 1; done; echo "$1 did not become ready on port $2" >&2; exit 1`, 'sh', service, String(port), port === 14500 ? ':100' : ':101'], 240_000)
  }
  /** caboose-display is ready once it answers a hello carrying this wake's token. */
  async function startCabooseDisplay(): Promise<void> {
    await command('/bin/sh', ['-c', 'systemctl start caboose-display.service; for i in $(seq 1 60); do if timeout 5 /usr/local/bin/caboose-session ready-display >/dev/null 2>&1; then exit 0; fi; sleep 1; done; echo "caboose-display did not become ready on port 14600" >&2; exit 1'], 240_000)
  }
  const controller: Controller = {
    displayUrl: `ws://${GUEST_ADDRESS}:${owner.port}/`,
    agentDisplayUrl: `ws://${GUEST_ADDRESS}:14501/`,
    async ensureAgentSeat() {
      // Same per-wake token file and user as the owner's display; started only when wanted.
      await startDisplay('caboose-xpra-agent.service', 14501)
    },
    guest() {
      if (!desk) return undefined
      return { run: (cmd: string, args: string[], timeoutMs?: number) => command(cmd, args, timeoutMs) }
    },
    stats: () => ({ host: 'caboose-host', kvm: existsSync('/dev/kvm'), desk: host.stats() }),
    activeResources: () => desk || existsSync(snapshotPath) ? resources : null,
    hasSavedState: () => Boolean(desk) || existsSync(snapshotPath),
    lastError: () => restartWarning,
    async wake(): Promise<Session> {
      const desired = settings()
      await Promise.all([
        ...(dependencies.deviceExists ? [] : [access('/dev/kvm', constants.R_OK | constants.W_OK)]),
        access(config.vmmPath, constants.X_OK),
        ...['base.raw', 'vmlinux', 'initrd'].map(file => access(join(config.imageRoot, file), constants.R_OK)),
      ])
      await mkdir(join(config.imageRoot, 'overlays'), { recursive: true })
      await mkdir(join(config.imageRoot, 'runtime'), { recursive: true })
      await (dependencies.network ?? ensureNetwork)()
      const restoring = existsSync(snapshotPath)
      const wasResident = Boolean(desk)
      desk = await host.start({ deskId: COMPUTER_ID, baseImage: join(config.imageRoot, 'base.raw'), overlayPath: join(config.imageRoot, 'overlays', `${COMPUTER_ID}.raw`), memoryMb: desired.memoryMb, vcpus: desired.vcpus, leaseMs: APPKIT_LEASE_MS, network: { tapDevice: TAP_DEVICE } })
      try {
        if (restoring && host.stats().lastError?.includes('could not resume from its snapshot')) {
          throw new Error(host.stats().lastError ?? 'Snapshot restore failed')
        }
        if (!restoring && !wasResident) {
          resources = { memoryMb: desired.memoryMb, vcpus: desired.vcpus }
          await writePrivateJson(resourcesPath, resources)
        }
        await configureGuest(desk)
        displayToken = randomBytes(32).toString('hex')
        // A password file is read by Xpra on connection; never put a newline in it.
        await command('/bin/sh', ['-c', `install -d -m 0755 /run/caboose; printf %s "$1" > /run/caboose/xpra-token; chown caboose:caboose /run/caboose/xpra-token; chmod 0600 /run/caboose/xpra-token`, 'sh', displayToken])
        if (config.display === 'caboose-display') await startCabooseDisplay()
        else await startDisplay('caboose-xpra.service', 14500)
        clearHeartbeat()
        heartbeat = setInterval(() => {
          try { desk?.renewLease(APPKIT_LEASE_MS) } catch (error) { console.error('Desk lease renewal failed:', error) }
        }, 20_000)
        heartbeat.unref()
        return { state: 'running', display: { path: '/v1/display', token: displayToken, protocol: config.display }, computer: { name: settings().name, image: 'Debian 13', ...(resources ?? { memoryMb: config.memoryMb, vcpus: config.vcpus }) } }
      } catch (error) {
        await host.suspend(COMPUTER_ID).catch(failure => console.error('Failed to park after wake error:', failure))
        desk = undefined
        throw error
      }
    },
    async park() {
      clearHeartbeat()
      await host.suspend(COMPUTER_ID)
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
      // snapshot; the disk is kept. Never destroy(), which deletes the user's disk.
      await host.shutdown(COMPUTER_ID)
      desk = undefined
      displayToken = ''
      // A computer parked before this host process started is unknown to appkit-desk,
      // so its snapshot is removed here too.
      await rm(snapshotPath, { recursive: true, force: true })
      resources = null
      return controller.wake()
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
  return controller
}
