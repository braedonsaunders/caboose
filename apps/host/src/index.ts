import { ActivityService, ActivityStore } from './activities.js'
import { APNsSender, apnsFromEnvironment } from './apns.js'
import { PushDevices, PushService } from './push.js'
import { config } from './config.js'
import { ComputerRegistry, OWNER_COMPUTER, PhoneTokens, type ComputerRecord } from './computers.js'
import { createContainerController } from './container-driver.js'
import { createController, createDeskPool } from './driver.js'
import { createCabooseServer, type ComputerPieces, type Controller } from './server.js'
import { describeHost, machineResources } from './host-info.js'
import { AgentRegistry } from './registry.js'
import { ComputerConflictError } from './lifecycle.js'
import { ownerToken } from './owner-token.js'
import { containerImage, describeImage, microvmImage, type ImageProvisioner } from './provision.js'
import { openSettings, type ComputerSettings } from './settings.js'
import { hostId, machineName, ReachService } from './reach.js'
import { join, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'

const deployment = config(process.env)
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
const apns = await apnsFromEnvironment(process.env)
const sender = apns ? new APNsSender(apns) : undefined
const computers = await ComputerRegistry.open(deployment.imageRoot)
const phones = await PhoneTokens.open(join(deployment.imageRoot, 'phones.json'))
// Every microVM computer shares one appkit-desk host, and with it its capacity.
const desks = deployment.runtime === 'microvm' ? createDeskPool(deployment) : undefined
const defaults = { memoryMb: deployment.memoryMb, vcpus: deployment.vcpus, idleMs: deployment.idleMs }

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
    : createController(deployment, { identity, ...(desks ? { desks } : {}), settings: () => settings.get() })
  return { settings, controller: withImage(controller, image), ...(push ? { push } : {}), ...(activities ? { activities } : {}) }
}

const ownerComputer = await open(computers.get(OWNER_COMPUTER)!)
const existing = []
for (const record of computers.list().filter(c => c.id !== OWNER_COMPUTER)) existing.push({ record, pieces: await open(record) })
const registry = new AgentRegistry({ url: deployment.agentRegistryUrl, cachePath: join(deployment.imageRoot, 'agent-registry.json') })
const webRoot = process.env.CABOOSE_WEB_ROOT ? resolve(process.env.CABOOSE_WEB_ROOT) : fileURLToPath(new URL('../../web/dist', import.meta.url))
const reach = new ReachService({
  bind: deployment.host, port: deployment.port, publicUrl: deployment.publicUrl, mdns: deployment.mdns,
  id: await hostId(join(deployment.imageRoot, 'host-id')),
  // Phones list hosts by name, so an unnamed host is told apart by its machine's name.
  name: () => {
    const name = ownerComputer.settings.get().name
    return name === 'Caboose' ? `Caboose on ${machineName()}` : name
  },
})
const host = describeHost(deployment, process.env, { push: !!sender, liveActivities: !!(apns && sender) })
const app = createCabooseServer({
  token: owner.token, ...ownerComputer, registry, host, agentIdleMs: deployment.agentIdleMs, webRoot,
  machine: () => machineResources(deployment.imageRoot), reach,
  fleet: { computers, phones, defaults, open, existing, maxRunning: deployment.runtime === 'microvm' ? deployment.maxRunning : null },
})
app.server.listen(deployment.port, deployment.host, () => {
  console.log(`caboose-host listening on ${deployment.host}:${deployment.port}`)
  void reach.start().catch(error => console.error('Advertising on the LAN (mDNS) failed:', error instanceof Error ? error.message : error))
})
// Fetch a missing image now rather than on the first wake; a failure is retried by the next wake.
void image.ensure().then(() => console.log(describeImage(image.status())), error => console.error(error instanceof Error ? error.message : error))
for (const signal of ['SIGTERM', 'SIGINT'] as const) {
  process.once(signal, () => {
    void reach.stop().catch(() => undefined).then(() => app.shutdown()).then(() => process.exit(0), error => { console.error('Shutdown failed:', error); process.exit(1) })
  })
}

/**
 * Wakes wait for the computer's image: while it downloads, a wake is refused with its
 * progress, and `GET /v1/health` reports it as `image`.
 */
function withImage(controller: Controller, provisioner: ImageProvisioner): Controller {
  const gated = Object.create(controller) as Controller
  gated.wake = async () => {
    // Checking for an image that is present takes moments; a download never holds a wake open.
    const ensured = provisioner.ensure().catch(() => undefined)
    await Promise.race([ensured, new Promise(resolve => setTimeout(resolve, 1000).unref())])
    const status = provisioner.status()
    if (status.state === 'fetching') throw new ComputerConflictError(describeImage(status))
    if (status.state === 'failed') throw new Error(describeImage(status))
    return controller.wake()
  }
  gated.stats = () => ({ ...(controller.stats() as object), image: provisioner.status() })
  return gated
}
