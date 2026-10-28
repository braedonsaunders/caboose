import { config } from './config.js'
import { createContainerController } from './container-driver.js'
import { createController } from './driver.js'
import { createCabooseServer } from './server.js'
import { AgentRegistry } from './registry.js'
import { openSettings } from './settings.js'
import { join, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'

const deployment = config(process.env)
const settings = await openSettings(join(deployment.imageRoot, 'caboose.json'), {
  name: 'Caboose', memoryMb: deployment.memoryMb, vcpus: deployment.vcpus, idleMs: deployment.idleMs, defaultAgent: null,
})
const registry = new AgentRegistry({ url: deployment.agentRegistryUrl, cachePath: join(deployment.imageRoot, 'agent-registry.json') })
const webRoot = process.env.CABOOSE_WEB_ROOT ? resolve(process.env.CABOOSE_WEB_ROOT) : fileURLToPath(new URL('../../web/dist', import.meta.url))
const app = createCabooseServer({ token: deployment.token, settings, registry, agentIdleMs: deployment.agentIdleMs,
  controller: deployment.runtime === 'container'
    ? createContainerController(deployment, { settings: () => settings.get() })
    : createController(deployment, { settings: () => settings.get() }), webRoot })
app.server.listen(deployment.port, deployment.host, () => console.log(`caboose-host listening on ${deployment.host}:${deployment.port}`))
for (const signal of ['SIGTERM', 'SIGINT'] as const) {
  process.once(signal, () => {
    void app.shutdown().then(() => process.exit(0), error => { console.error('Shutdown failed:', error); process.exit(1) })
  })
}
