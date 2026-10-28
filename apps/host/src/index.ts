import { config } from './config.js'
import { createContainerController } from './container-driver.js'
import { createController } from './driver.js'
import { createCabooseServer } from './server.js'

const settings = config(process.env)
const app = createCabooseServer({ token: settings.token, idleMs: settings.idleMs, controller: settings.runtime === 'container' ? createContainerController(settings) : createController(settings) })
app.server.listen(settings.port, settings.host, () => console.log(`caboose-host listening on ${settings.host}:${settings.port}`))
for (const signal of ['SIGTERM', 'SIGINT'] as const) {
  process.once(signal, () => {
    void app.shutdown().then(() => process.exit(0), error => { console.error('Shutdown failed:', error); process.exit(1) })
  })
}
