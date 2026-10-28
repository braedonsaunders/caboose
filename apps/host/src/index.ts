import { ActivityService, ActivityStore } from './activities.js'
import { APNsSender, apnsFromEnvironment } from './apns.js'
import { PushDevices, PushService } from './push.js'
import { config } from './config.js'
import { createContainerController } from './container-driver.js'
import { createController } from './driver.js'
import { createCabooseServer, type Controller } from './server.js'
import { describeHost, machineResources } from './host-info.js'
import { AgentRegistry } from './registry.js'
import { ComputerConflictError } from './lifecycle.js'
import { ownerToken } from './owner-token.js'
import { containerImage, describeImage, microvmImage, type ImageProvisioner } from './provision.js'
import { openSettings } from './settings.js'
import { join, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'

const deployment = config(process.env)
const owner = deployment.token ? { token: deployment.token, created: false } : await ownerToken(join(deployment.imageRoot, 'owner-token'))
if (!deployment.token) {
  console.log(owner.created
    ? `Generated the owner token in ${join(deployment.imageRoot, 'owner-token')}. Sign in to the console with it.`
    : `Using the owner token in ${join(deployment.imageRoot, 'owner-token')}.`)
}
const image = deployment.runtime === 'container'
  ? containerImage({ image: deployment.containerImage })
  : microvmImage({ imageRoot: deployment.imageRoot, reference: deployment.baseImage })
const settings = await openSettings(join(deployment.imageRoot, 'caboose.json'), {
  name: 'Caboose', memoryMb: deployment.memoryMb, vcpus: deployment.vcpus, idleMs: deployment.idleMs, defaultAgent: null,
})
const apns = await apnsFromEnvironment(process.env)
const sender = apns ? new APNsSender(apns) : undefined
const push = sender ? new PushService(await PushDevices.open(join(deployment.imageRoot, 'push-devices.json')), sender) : undefined
const activities = apns && sender ? new ActivityService(await ActivityStore.open(join(deployment.imageRoot, 'activities.json')), message => sender.send(message), apns.topic) : undefined
const registry = new AgentRegistry({ url: deployment.agentRegistryUrl, cachePath: join(deployment.imageRoot, 'agent-registry.json') })
const webRoot = process.env.CABOOSE_WEB_ROOT ? resolve(process.env.CABOOSE_WEB_ROOT) : fileURLToPath(new URL('../../web/dist', import.meta.url))
const host = describeHost(deployment, process.env, { push: !!push, liveActivities: !!activities })
const app = createCabooseServer({ token: owner.token, settings, registry, push, activities, host, agentIdleMs: deployment.agentIdleMs,
  machine: () => machineResources(deployment.imageRoot),
  controller: withImage(deployment.runtime === 'container'
    ? createContainerController(deployment, { settings: () => settings.get() })
    : createController(deployment, { settings: () => settings.get() }), image), webRoot })
app.server.listen(deployment.port, deployment.host, () => console.log(`caboose-host listening on ${deployment.host}:${deployment.port}`))
// Fetch a missing image now rather than on the first wake; a failure is retried by the next wake.
void image.ensure().then(() => console.log(describeImage(image.status())), error => console.error(error instanceof Error ? error.message : error))
for (const signal of ['SIGTERM', 'SIGINT'] as const) {
  process.once(signal, () => {
    void app.shutdown().then(() => process.exit(0), error => { console.error('Shutdown failed:', error); process.exit(1) })
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
