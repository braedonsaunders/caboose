import { randomBytes } from 'node:crypto'
import { constants, existsSync } from 'node:fs'
import { access, mkdir, readFile } from 'node:fs/promises'
import { join } from 'node:path'
import { createDeskHost, createCloudHypervisorBackend, type DeskHandle, type DeskBackend } from '@braedonsaunders/appkit-desk'
import type { Config } from './config.js'
import { configureGuest, ensureNetwork, GUEST_ADDRESS, TAP_DEVICE } from './network.js'
import type { App, Controller, Session } from './server.js'

const COMPUTER_ID = 'owner'
const APPKIT_LEASE_MS = 90_000
export function createController(config: Config, dependencies: { backend?: DeskBackend; network?: () => Promise<void>; deviceExists?: (path: string) => boolean } = {}): Controller {
  const host = createDeskHost({
    imageRoot: config.imageRoot, vmmPath: config.vmmPath,
    kernelCmdline: 'console=ttyS0 root=/dev/vda3 rw',
    runtimeDir: join(config.imageRoot, 'runtime'), backend: dependencies.backend ?? createCloudHypervisorBackend({ connectTimeoutMs: 120_000 }),
    ...(dependencies.deviceExists ? { deviceExists: dependencies.deviceExists } : {}),
    parkWithMemory: true, idleSuspendMs: APPKIT_LEASE_MS, defaultLeaseMs: APPKIT_LEASE_MS,
    ports: { onEvent: () => {}, audit: () => {} },
  })
  let desk: DeskHandle | undefined
  let heartbeat: ReturnType<typeof setInterval> | undefined
  let displayToken = ''
  async function command(command: string, args: string[], timeoutMs = 30_000): Promise<string> {
    if (!desk) throw new Error('Computer is not running')
    const result = await desk.exec({ command, args, timeoutMs })
    if (result.exitCode !== 0 || result.truncated) throw new Error(`Guest command failed: ${result.stderr || result.exitCode}`)
    return result.stdout
  }
  async function guestApps(action: string, id?: string): Promise<string> {
    const script = await readFile(new URL('./guest-apps.py', import.meta.url), 'utf8')
    return command('/usr/sbin/runuser', ['-u', 'caboose', '--', '/usr/bin/env', 'DISPLAY=:100', '/usr/bin/python3', '-c', script, action, ...(id ? [id] : [])], 60_000)
  }
  async function startDisplay(service: string, port: number): Promise<void> {
    // systemd and the listening socket can be ready before Xpra can serve a hello.
    await command('/bin/sh', ['-c', `systemctl start "$1"; for i in $(seq 1 60); do if systemctl is-active --quiet "$1" && ss -lnt | grep -Eq ":$2[[:space:]]" && timeout 3 runuser -u caboose -- xpra info "$3" >/dev/null 2>&1; then exit 0; fi; sleep 1; done; echo "$1 did not become ready on port $2" >&2; exit 1`, 'sh', service, String(port), port === 14500 ? ':100' : ':101'], 240_000)
  }
  return {
    displayUrl: `ws://${GUEST_ADDRESS}:14500/`,
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
    async wake(): Promise<Session> {
      await Promise.all([
        ...(dependencies.deviceExists ? [] : [access('/dev/kvm', constants.R_OK | constants.W_OK)]),
        access(config.vmmPath, constants.X_OK),
        ...['base.raw', 'vmlinux', 'initrd'].map(file => access(join(config.imageRoot, file), constants.R_OK)),
      ])
      await mkdir(join(config.imageRoot, 'overlays'), { recursive: true })
      await mkdir(join(config.imageRoot, 'runtime'), { recursive: true })
      await (dependencies.network ?? ensureNetwork)()
      const snapshotPath = join(config.imageRoot, 'overlays', `${COMPUTER_ID}.snapshot`)
      const restoring = existsSync(snapshotPath)
      desk = await host.start({ deskId: COMPUTER_ID, baseImage: join(config.imageRoot, 'base.raw'), overlayPath: join(config.imageRoot, 'overlays', `${COMPUTER_ID}.raw`), memoryMb: config.memoryMb, vcpus: config.vcpus, leaseMs: APPKIT_LEASE_MS, network: { tapDevice: TAP_DEVICE } })
      try {
        if (restoring && host.stats().lastError?.includes('could not resume from its snapshot')) {
          throw new Error(host.stats().lastError ?? 'Snapshot restore failed')
        }
        await configureGuest(desk)
        displayToken = randomBytes(32).toString('hex')
        // A password file is read by Xpra on connection; never put a newline in it.
        await command('/bin/sh', ['-c', `install -d -m 0755 /run/caboose; printf %s "$1" > /run/caboose/xpra-token; chown caboose:caboose /run/caboose/xpra-token; chmod 0600 /run/caboose/xpra-token`, 'sh', displayToken])
        await startDisplay('caboose-xpra.service', 14500)
        heartbeat = setInterval(() => {
          try { desk?.renewLease(APPKIT_LEASE_MS) } catch (error) { console.error('Desk lease renewal failed:', error) }
        }, 20_000)
        heartbeat.unref()
        return { state: 'running', display: { path: '/v1/display', token: displayToken, protocol: 'xpra-ws' }, computer: { name: 'Caboose', image: 'Debian 13', memoryMb: config.memoryMb, vcpus: config.vcpus } }
      } catch (error) {
        await host.suspend(COMPUTER_ID).catch(failure => console.error('Failed to park after wake error:', failure))
        desk = undefined
        throw error
      }
    },
    async park() {
      if (heartbeat) clearInterval(heartbeat)
      heartbeat = undefined
      await host.suspend(COMPUTER_ID)
      desk = undefined
      displayToken = ''
      if (!existsSync(join(config.imageRoot, 'overlays', `${COMPUTER_ID}.snapshot`))) {
        throw new Error(host.stats().lastError ?? 'Memory snapshot was not created')
      }
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
