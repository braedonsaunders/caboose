import { ActivityService, ActivityStore } from './activities.js'
import { APNsSender, apnsFromEnvironment } from './apns.js'
import { PushDevices, PushService } from './push.js'
import { config } from './config.js'
import { ComputerRegistry, OWNER_COMPUTER, PhoneTokens, type ComputerRecord } from './computers.js'
import { createContainerController } from './container-driver.js'
import { createController, createDeskPool } from './driver.js'
import { createCabooseServer, type ComputerPieces } from './server.js'
import { describeHost, machineResources } from './host-info.js'
import { AgentRegistry } from './registry.js'
import { openSettings, type ComputerSettings } from './settings.js'
import { join, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'

const deployment = config(process.env)
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
  return { settings, controller, ...(push ? { push } : {}), ...(activities ? { activities } : {}) }
}

const owner = await open(computers.get(OWNER_COMPUTER)!)
const existing = []
for (const record of computers.list().filter(c => c.id !== OWNER_COMPUTER)) existing.push({ record, pieces: await open(record) })
const registry = new AgentRegistry({ url: deployment.agentRegistryUrl, cachePath: join(deployment.imageRoot, 'agent-registry.json') })
const webRoot = process.env.CABOOSE_WEB_ROOT ? resolve(process.env.CABOOSE_WEB_ROOT) : fileURLToPath(new URL('../../web/dist', import.meta.url))
const host = describeHost(deployment, process.env, { push: !!sender, liveActivities: !!(apns && sender) })
const app = createCabooseServer({
  token: deployment.token, ...owner, registry, host, agentIdleMs: deployment.agentIdleMs, webRoot,
  machine: () => machineResources(deployment.imageRoot),
  fleet: { computers, phones, defaults, open, existing, maxRunning: deployment.runtime === 'microvm' ? deployment.maxRunning : null },
})
app.server.listen(deployment.port, deployment.host, () => console.log(`caboose-host listening on ${deployment.host}:${deployment.port}`))
for (const signal of ['SIGTERM', 'SIGINT'] as const) {
  process.once(signal, () => {
    void app.shutdown().then(() => process.exit(0), error => { console.error('Shutdown failed:', error); process.exit(1) })
  })
}
