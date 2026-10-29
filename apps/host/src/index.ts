import { vmPaths } from './vm-paths.js'
import { usesSystemImage, validateDepotRestoreOptions } from './system-image.js'
import { prepareKeyring } from './keyring.js'
import { AgentToolJournal } from './agent-tools-journal.js'
import { AgentRoutines } from './agent-routines.js'
import { ActivityService, ActivityStore } from './activities.js'
import { APNsSender, apnsFromEnvironment } from './apns.js'
import { PushDevices, PushService } from './push.js'
import { config } from './config.js'
import { createStorageFromEnv } from '@braedonsaunders/appkit-storage/env'
import { snapshotTierKey } from './snapshot-tier-config.js'
import { startSnapshotGc } from './snapshot-tier-gc.js'
import { ComputerRegistry, OWNER_COMPUTER, PhoneTokens, type ComputerRecord } from './computers.js'
import { createContainerController, DEPOT_VOLUME, securityArgs } from './container-driver.js'
import { containerDepotRunner, RuntimeDepot } from './depot.js'
import { FlathubIndex } from './flathub.js'
import { SmitheryCatalog } from './smithery.js'
import { CraftReleases } from './releases.js'
import { createController, createDeskPool } from './driver.js'
import { openStorage } from './storage.js'
import { createCabooseServer, type ComputerPieces, type Controller } from './server.js'
import type { Architecture } from './app-catalog-data.js'
import { describeHost, machineResources } from './host-info.js'
import { AgentRegistry } from './registry.js'
import { AgentProfiles } from './agent-profiles.js'
import { ComputerConflictError } from './lifecycle.js'
import { ownerToken, secretFile } from './owner-token.js'
import { openIdentityDatabase } from './identity/database.js'
import { Identity } from './identity/service.js'
import { lstat, mkdir, readdir, readFile } from 'node:fs/promises'
import { containerImage, describeImage, microvmImage, type ImageProvisioner } from './provision.js'
import { openSettings, type ComputerSettings } from './settings.js'
import { hostId, machineName, ReachService } from './reach.js'
import { join, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'
import { spawn, spawnSync } from 'node:child_process'
import { fstatSync, statSync } from 'node:fs'

const deployment = config(process.env)
if (process.platform === 'linux' && deployment.runtime === 'microvm') {
  if (!process.env.CABOOSE_HOST_LOCK_FD) {
    const helper = fileURLToPath(new URL('./host-lock.py', import.meta.url))
    const child = spawn('python3', [helper, deployment.imageRoot, process.execPath, ...process.execArgv, ...process.argv.slice(1)], { stdio: 'inherit' })
    for (const signal of ['SIGTERM', 'SIGINT'] as const) process.on(signal, () => child.kill(signal))
    const status = await new Promise<number>((resolveStatus, reject) => {
      child.once('error', reject)
      child.once('exit', (code, signal) => resolveStatus(code ?? (signal ? 1 : 0)))
    })
    process.exit(status)
  }
  const fd = Number(process.env.CABOOSE_HOST_LOCK_FD)
  if (fd !== 3) throw new Error('Invalid host lock descriptor')
  const held = fstatSync(fd)
  const path = statSync(join(deployment.imageRoot, '.host.lock'))
  if (!held.isFile() || held.dev !== path.dev || held.ino !== path.ino) throw new Error('Host lock descriptor does not match image root')
  // Reassert the lock on the same open file description, including on a direct exec.
  const verified = spawnSync('python3', ['-c', 'import fcntl; fcntl.flock(3, fcntl.LOCK_EX | fcntl.LOCK_NB)'], { stdio: ['ignore', 'ignore', 'pipe', fd] })
  if (verified.status !== 0) throw new Error('Could not verify exclusive host lock')
  const overlays = join(deployment.imageRoot, 'overlays')
  const entries = await readdir(overlays).catch(error => {
    if ((error as NodeJS.ErrnoException).code === 'ENOENT') return []
    throw error
  })
  if (entries.some(name => name.endsWith('.migration.json'))) throw new Error('An unfinished disk migration must be recovered before starting the host')
}
const tierKey = await snapshotTierKey(process.env, deployment.runtime)
const tierStore = tierKey ? createStorageFromEnv(process.env) : undefined
const snapshotGc = tierStore && tierKey ? startSnapshotGc(join(deployment.imageRoot, 'overlays'), tierStore, tierKey) : undefined
const owner = deployment.token ? { token: deployment.token, created: false } : await ownerToken(join(deployment.imageRoot, 'owner-token'))
if (!deployment.token) {
  console.log(owner.created
    ? `Generated the owner token in ${join(deployment.imageRoot, 'owner-token')}. Sign in to the console with it.`
    : `Using the owner token in ${join(deployment.imageRoot, 'owner-token')}.`)
}
// One provisioner for every computer: they all boot from the same image.
const image = deployment.runtime === 'container'
  ? containerImage({ image: deployment.containerImage })
  : microvmImage({ imageRoot: deployment.imageRoot, reference: deployment.baseImage })
// Accounts and tenants: Postgres when CABOOSE_DATABASE_URL names one, otherwise embedded.
const identityDatabase = await openIdentityDatabase({ url: deployment.databaseUrl, dataDir: join(deployment.imageRoot, 'identity') })
const identity = Identity.create({
  database: identityDatabase,
  baseURL: deployment.publicUrl ?? `http://127.0.0.1:${deployment.port}`,
  secret: process.env.CABOOSE_AUTH_SECRET || (await secretFile(join(deployment.imageRoot, 'auth-secret'))).token,
  setupCodePath: join(deployment.imageRoot, 'setup-code'),
})
const apns = await apnsFromEnvironment(process.env)
const sender = apns ? new APNsSender(apns) : undefined
const computers = await ComputerRegistry.open(deployment.imageRoot, identityDatabase)
const phones = await PhoneTokens.open(join(deployment.imageRoot, 'phones.json'))
// Every microVM computer shares one appkit-desk host, and with it its capacity.
const desks = deployment.runtime === 'microvm' ? createDeskPool(deployment) : undefined
const splitImage = process.env.CABOOSE_SPLIT_IMAGE || undefined
const vmDepot = deployment.runtime === 'microvm' && process.env.CABOOSE_VM_DEPOT ? resolve(process.env.CABOOSE_VM_DEPOT) : undefined
validateDepotRestoreOptions(vmDepot, process.env.CABOOSE_VM_COW)
if (vmDepot && /[:\n\r]/.test(vmDepot)) throw new Error('CABOOSE_VM_DEPOT cannot contain a colon or newline')
if (vmDepot && process.platform !== 'linux') throw new Error('CABOOSE_VM_DEPOT requires a Linux microVM host')
if (vmDepot) await mkdir(vmDepot, { recursive: true, mode: 0o755 })
const defaults = { memoryMb: deployment.memoryMb, vcpus: deployment.vcpus, idleMs: deployment.idleMs }
// Shared storage and phone backups for microVM computers.
const storage = await openStorage(deployment, process.env)

/** A computer's settings, runtime and notifications, from its own directory. */
async function open(record: ComputerRecord, initial?: ComputerSettings): Promise<ComputerPieces> {
  const dir = computers.dataDir(record.id)
  const settings = await openSettings(join(dir, 'caboose.json'), initial ?? { name: record.id === OWNER_COMPUTER ? 'Caboose' : 'Computer', defaultAgent: null, ...defaults })
  // A new computer's choices are saved at once, so a host restart keeps them.
  if (initial) await settings.update({ name: initial.name, memoryMb: initial.memoryMb, vcpus: initial.vcpus, idleMs: initial.idleMs })
  const push = sender ? new PushService(await PushDevices.open(join(dir, 'push-devices.json')), sender) : undefined
  const activities = apns && sender ? new ActivityService(await ActivityStore.open(join(dir, 'activities.json')), message => sender.send(message), apns.topic) : undefined
  const identity = { id: record.id, slot: record.slot }
  const controller = deployment.runtime === 'container'
    ? createContainerController(deployment, { identity, settings: () => settings.get() })
    : createController(deployment, { identity, splitImage, depotPath: vmDepot, parkedFilesEnabled: deployment.parkedFiles, ...(desks ? { desks } : {}), settings: () => settings.get() })
  const profiles = await AgentProfiles.open(join(dir, 'agent-profiles.json'))
  const paths = vmPaths(deployment.imageRoot, record.id, deployment.vmTemplate)
  const snapshotPath = paths.snapshot
  const computerStorage = storage.forComputer(record.id, controller, phoneId => phones.list(record.id).find(phone => phone.id === phoneId)?.name)
  return { ...(computerStorage ? { storage: computerStorage } : {}), ...(deployment.runtime === 'microvm' ? { snapshotPath, ...(tierStore && tierKey ? { snapshotTier: { store: tierStore, key: tierKey, delayMs: 4 * 60 * 60_000 } } : {}) } : {}), settings, profiles, mcpLibraryFile: join(dir, 'mcp-library.json'), prepareKeyring: () => prepareKeyring(join(dir, 'keyring-secret'), controller.fileService!()), openToolJournal: dispatch => AgentToolJournal.open(join(dir, 'agent-tool-receipts.json'), dispatch), openRoutines: options => AgentRoutines.open(join(dir, 'agent-routines.json'), options), controller: withImage(controller, image, deployment.runtime === 'microvm' ? () => usesSystemImage(join(deployment.imageRoot, 'overlays', `${record.id}.system-image.json`), paths.disk, snapshotPath, splitImage) : undefined), ...(push ? { push } : {}), ...(activities ? { activities } : {}) }
}

const ownerComputer = await open(computers.get(OWNER_COMPUTER)!)
const existing = []
for (const record of computers.list().filter(c => c.id !== OWNER_COMPUTER)) existing.push({ record, pieces: await open(record) })
const guestArchitecture = process.arch === 'arm64' ? 'arm64' : 'amd64'
const registry = new AgentRegistry({ platform: guestArchitecture === 'arm64' ? 'linux-aarch64' : 'linux-x86_64', url: deployment.agentRegistryUrl, cachePath: join(deployment.imageRoot, 'agent-registry.json') })
const webRoot = process.env.CABOOSE_WEB_ROOT ? resolve(process.env.CABOOSE_WEB_ROOT) : fileURLToPath(new URL('../../web/dist', import.meta.url))
const thisHost = await hostId(join(deployment.imageRoot, 'host-id'))
const reach = new ReachService({
  bind: deployment.host, port: deployment.port, publicUrl: deployment.publicUrl, mdns: deployment.mdns,
  id: thisHost,
  // Phones list hosts by name, so an unnamed host is told apart by its machine's name.
  name: () => {
    const name = ownerComputer.settings.get().name
    return name === 'Caboose' ? `Caboose on ${machineName()}` : name
  },
})
// The Library's host-wide parts: Flathub's index, the Craft releases, the shared runtimes and
// the architecture that picks a game's native build.
const flatpakArch: Architecture = guestArchitecture === 'arm64' ? 'aarch64' : 'x86_64'
const depotRunner = deployment.runtime === 'container'
  ? containerDepotRunner({ image: deployment.containerImage, volume: DEPOT_VOLUME, securityArgs: securityArgs(deployment.containerArgs), script: () => readFile(new URL('./depot-builder.py', import.meta.url), 'utf8') })
  : vmDepot ? containerDepotRunner({ image: deployment.containerImage, volume: vmDepot, securityArgs: securityArgs(deployment.containerArgs), script: () => readFile(new URL('./depot-builder.py', import.meta.url), 'utf8') }) : null
// Populate the repository before any guest probes its shared installation.
if (vmDepot && depotRunner) await depotRunner(['list'], () => {}, 10 * 60_000)
const library = {
  flathub: new FlathubIndex(join(deployment.imageRoot, 'flathub'), flatpakArch),
  releases: new CraftReleases(join(deployment.imageRoot, 'releases'), flatpakArch),
  depot: new RuntimeDepot(depotRunner, join(deployment.imageRoot, 'depot.json')),
  arch: flatpakArch,
  // MCP servers, from Smithery; each computer connects its own Smithery account.
  mcp: { catalog: new SmitheryCatalog(join(deployment.imageRoot, 'smithery')), hostId: thisHost },
}
void library.flathub.ready().catch(error => console.error('Flathub index unavailable:', error instanceof Error ? error.message : error))
const host = describeHost(deployment, process.env, { push: !!sender, liveActivities: !!(apns && sender) })
const app = createCabooseServer({
  token: owner.token, ...ownerComputer, registry, library, host, agentIdleMs: deployment.agentIdleMs, freezeParkMs: deployment.freezeParkMs, webRoot,
  machine: () => machineResources(deployment.imageRoot), reach, sharedStorage: () => storage.sharedStorage(),
  fleet: { computers, phones, defaults, open, existing, maxRunning: deployment.runtime === 'microvm' ? deployment.maxRunning : null, diskBytes },
  identity,
})
app.server.listen(deployment.port, deployment.host, () => {
  console.log(`caboose-host listening on ${deployment.host}:${deployment.port}`)
  void reach.start().catch(error => console.error('Advertising on the LAN (mDNS) failed:', error instanceof Error ? error.message : error))
  // An unclaimed host prints its one-time setup link; the installers read the same code from the file.
  void identity.setupCode().then(code => {
    if (!code) return
    const address = deployment.host === '0.0.0.0' || deployment.host === '::' ? '127.0.0.1' : deployment.host
    console.log(`Set up Caboose: http://${address.includes(':') ? `[${address}]` : address}:${deployment.port}/setup?code=${code}`)
  }, error => console.error('Could not write the setup code:', error))
})
// Fetch a missing image now rather than on the first wake; a failure is retried by the next wake.
void image.ensure().then(() => console.log(describeImage(image.status())), error => console.error(error instanceof Error ? error.message : error))
for (const signal of ['SIGTERM', 'SIGINT'] as const) {
  process.once(signal, () => {
    void reach.stop().catch(() => undefined).then(() => app.shutdown()).then(() => storage.close()).then(() => snapshotGc?.close()).then(() => identityDatabase.close()).then(() => process.exit(0), error => { console.error('Shutdown failed:', error); process.exit(1) })
  })
}

/**
 * Wakes wait for the computer's image: while it downloads, a wake is refused with its
 * progress, and `GET /v1/health` reports it as `image`.
 */
function withImage(controller: Controller, provisioner: ImageProvisioner, useSplit?: () => Promise<boolean>): Controller {
  const gated = Object.create(controller) as Controller
  gated.wake = async (mode) => {
    if (await useSplit?.()) return controller.wake(mode)
    // Checking for an image that is present takes moments; a download never holds a wake open.
    const ensured = provisioner.ensure().catch(() => undefined)
    await Promise.race([ensured, new Promise(resolve => setTimeout(resolve, 1000).unref())])
    const status = provisioner.status()
    if (status.state === 'fetching') throw new ComputerConflictError(describeImage(status))
    if (status.state === 'failed') throw new Error(describeImage(status))
    if (status.state === 'missing') throw new ComputerConflictError(missingImage())
    return controller.wake(mode)
  }
  gated.stats = () => ({ ...(controller.stats() as object), image: provisioner.status() })
  return gated
}

/** What an owner does when the computer's image is absent and the host has none to fetch. */
function missingImage(): string {
  return deployment.runtime === 'container'
    ? `The computer's image ${deployment.containerImage} is not in Docker. Build it with docker build -t ${deployment.containerImage} -f guest/container/Dockerfile guest, or set CABOOSE_CONTAINER_IMAGE to a published image.`
    : `The computer's image is not installed. Build it into ${deployment.imageRoot} with guest/image/build.sh, or set CABOOSE_BASE_IMAGE to a published image.`
}

/** The disk a microVM computer uses on the host: its overlay and any parked memory. Unknown for a container. */
async function diskBytes(record: ComputerRecord): Promise<number | null> {
  if (deployment.runtime !== 'microvm') return null
  const paths = vmPaths(deployment.imageRoot, record.id, deployment.vmTemplate)
  return await allocated(paths.disk) + await allocated(paths.snapshot)
}

/** Bytes allocated to a file or directory tree (sparse files count only what they hold). */
async function allocated(path: string): Promise<number> {
  const info = await lstat(path).catch(() => null)
  if (!info) return 0
  if (!info.isDirectory()) return info.blocks * 512
  let total = 0
  for (const entry of await readdir(path)) total += await allocated(join(path, entry))
  return total
}
