import { upgradeComponents, type ComponentsMode, type UpgradeStatus } from './components.js'
import { parseCraftRequest, runCraft } from './craft-jobs.js'
import { proxyFiles, type FileService } from './fs-proxy.js'
import { agentJob, parseJob, type ActivityService } from './activities.js'
import { rm } from 'node:fs/promises'
import { createServer, type IncomingMessage, type ServerResponse } from 'node:http'
import type { Duplex } from 'node:stream'
import { WebSocket, WebSocketServer } from 'ws'
import { authenticate } from './auth.js'
import { AgentCatalog } from './agent-catalog.js'
import { AppCatalog, craftMcpServers } from './app-catalog.js'
import { AgentConflictError, AgentInputError, AgentNotFoundError, AgentOperationError, AgentTasks, AgentUnavailableError, type AgentGuest } from './agents.js'
import { openUrl, openOnDisplay, decodeBase64, sanitizeFileName, splitName, DOWNLOADS } from './files.js'
import { ComputerConflictError, ComputerLifecycle, type ComputerDriver } from './lifecycle.js'
import { HomeOwnership } from './home.js'
import { MediaHandoff, MediaInputError, parseMediaCommand } from './media.js'
import { AgentRegistry } from './registry.js'
import { PhoneHandoff, readPhoneFile } from './phone.js'
import { SettingsInputError, settingsLimits, updateSettings, type ComputerSettings, type SettingsStore } from './settings.js'
import { MAX_SLOTS } from './network.js'
import { ComputerCapacityError, OWNER_COMPUTER, type ComputerRecord, type ComputerRegistry, type PhoneTokens } from './computers.js'
import type { DisplayProtocol } from './config.js'
import { DisplayNotReadyError } from './display.js'
import type { ComputerResources } from './driver.js'
import { serveWeb } from './static.js'
import { DesktopNotifications } from './desktop-notifications.js'
import type { PushService } from './push.js'
import type { HostInfo, MachineResources } from './host-info.js'
import type { AgentEvent } from './agents.js'
import { ScreenElementGoneError, screenAct, screenElements, screenKeys, screenType } from './screen.js'

export interface App { id: string; name: string; icon: string; categories: string[]; exec: string }
export interface Session { state: string; display: { path: string; token: string; protocol: DisplayProtocol }; computer: { name: string; image: string; memoryMb: number; vcpus: number } }
export interface Controller extends ComputerDriver<Session> {
  componentsMode?: ComponentsMode
  componentsWarning?(): string | undefined
  stats(): unknown
  apps(): Promise<App[]>
  launch(id: string, path?: string): Promise<void>
  /** The owner's display in the guest: caboose-display's WebSocket. */
  displayUrl: string
  /** The agent seat's caboose-display, started on demand by ensureAgentSeat. */
  agentDisplayUrl: string
  ensureAgentSeat(): Promise<void>
  /** Root command runner in the running computer, or undefined while parked. */
  guest(): AgentGuest | undefined
  fileService?(): FileService
  activeResources(): ComputerResources | null
  hasSavedState(): boolean
  lastError?(): string | null
  /** Deletes the computer and its disk; only when the computer itself is deleted. */
  destroy?(): Promise<void>
}

/** Body limits: base64 inflates by a third, plus room for the JSON around it. */
const TASK_BODY_LIMIT = 15 * 1024 * 1024

async function readJson(request: IncomingMessage, limit = 64 * 1024): Promise<Record<string, unknown>> {
  const chunks: Buffer[] = []
  let size = 0
  for await (const chunk of request) {
    size += chunk.length
    if (size > limit) throw new AgentInputError('request body too large')
    chunks.push(chunk as Buffer)
  }
  if (!size) return {}
  try {
    const value = JSON.parse(Buffer.concat(chunks).toString('utf8'))
    if (value && typeof value === 'object' && !Array.isArray(value)) return value as Record<string, unknown>
  } catch {}
  throw new AgentInputError('request body must be a JSON object')
}

/** Who a request is from: the owner (the host's own token), or a phone signed in to one computer. */
export type Principal = { kind: 'owner'; phoneId?: undefined } | { kind: 'phone'; phoneId: string; computerId: string }

/** What one computer is made of: its settings, its runtime, and the notifications its phones get. */
export interface ComputerPieces { settings: SettingsStore; controller: Controller; push?: PushService; activities?: ActivityService }

/** A computer route that does not exist, as opposed to one that answered. */
const NOT_FOUND = Symbol('not found')

function json(response: ServerResponse, status: number, body: unknown): void {
  response.writeHead(status, { 'content-type': 'application/json', 'cache-control': 'no-store' })
  response.end(JSON.stringify(body))
}

/**
 * Everything one computer serves: its lifecycle and leases, sockets and display relay, agents,
 * catalog, files, media, and the push and Live Activity registrations of its phones.
 */
function createComputerRuntime(id: string, pieces: ComputerPieces, shared: { registry: AgentRegistry; agentIdleMs?: number }) {
  const { controller, settings, push, activities } = pieces
  const computer = new ComputerLifecycle(controller, settings.get().idleMs)
  const sockets = new Set<WebSocket>()
  const controls = new Set<WebSocket>()
  const foregroundClients = new Set<WebSocket>()
  const phoneControls = new Set<WebSocket>()
  const wss = new WebSocketServer({ noServer: true, maxPayload: 16 * 1024 * 1024, handleProtocols: protocols => protocols.has('binary') ? 'binary' : false })
  function broadcast(event: unknown): void {
    const message = JSON.stringify(event)
    for (const socket of controls) if (socket.readyState === WebSocket.OPEN) socket.send(message)
  }
  let upgrade: UpgradeStatus | null = null
  let upgrading = false
  let upgradeWork: Promise<void> | undefined
  function publishUpgrade(status: UpgradeStatus): void {
    const warning = controller.componentsWarning?.()
    upgrade = warning && status.state === 'succeeded' ? { ...status, message: warning } : status
    broadcast({ type: 'computer.upgrade', upgrade })
    broadcastSettings()
  }
  const home = new HomeOwnership()
  const catalog = new AgentCatalog(shared.registry, () => controller.guest(), settings, home)
  const appCatalog = new AppCatalog(() => controller.guest(), broadcast, () => computer.acquire())
  const agents = new AgentTasks(() => controller.guest(), event => {
    broadcast(event)
    if (push) void push.event(event as AgentEvent, foregroundClients.size > 0).catch(error => console.error('Push event failed:', error))
    const job = agentJob(event as AgentEvent)
    if (job && activities) void activities.job(job, event.type === 'agent.task.started' || event.type === 'agent.task.replied', foregroundClients.size > 0).catch(error => console.error('Live Activity event failed:', error))
  }, () => computer.acquire(), {
    resolver: catalog, home, craftServers: async () => craftMcpServers((await appCatalog.list()).apps), pollMs: 1000, ensureSeat: () => controller.ensureAgentSeat(), ...(shared.agentIdleMs !== undefined ? { idleMs: shared.agentIdleMs } : {}),
  })
  const desktopNotifications = new DesktopNotifications(() => controller.guest(), event => {
    broadcast({ type: 'notification', ...event })
    if (push) void push.desktop(event, foregroundClients.size > 0).catch(error => console.error('Desktop push failed:', error))
  })
  let craftBusy = 0
  const craftJobs = new Set<string>()
  const media = new MediaHandoff(() => controller.guest(), broadcast)
  let fileAnchor: string | undefined
  let filePoll: ReturnType<typeof setInterval> | undefined
  let pollingFiles = false
  function syncFiles(): void {
    const active = computer.state === 'running' && controls.size > 0 && controller.fileService
    if (!active) {
      if (filePoll) clearInterval(filePoll)
      filePoll = undefined
      fileAnchor = undefined
      return
    }
    if (filePoll) return
    const poll = async () => {
      if (pollingFiles || !controller.fileService || computer.state !== 'running') return
      pollingFiles = true
      try {
        const service = controller.fileService()
        const url = new URL('/changes', service.url)
        if (fileAnchor) url.searchParams.set('anchor', fileAnchor)
        const response = await fetch(url, { headers: { authorization: `Bearer ${service.token}` }, signal: AbortSignal.timeout(5000) })
        if (!response.ok) throw new Error('File change feed unavailable')
        const change = await response.json() as { anchor: string; changed: boolean }
        if (fileAnchor && change.changed) broadcast({ type: 'fs.changed', anchor: change.anchor })
        fileAnchor = change.anchor
      } catch { /* Retry with the previous anchor so missed changes trigger a rescan. */ }
      finally { pollingFiles = false }
    }
    void poll()
    filePoll = setInterval(() => { void poll() }, 1000)
    filePoll.unref()
  }

  const phone = new PhoneHandoff(() => controller.guest(), event => {
    const message = JSON.stringify(event)
    for (const socket of phoneControls) if (socket.readyState === WebSocket.OPEN) socket.send(message)
  })
  /** Media is polled only while the computer is already running and someone is watching it. */
  function syncMedia(): void {
    media.setActive(computer.state === 'running' && sockets.size - controls.size > 0)
    phone.setActive(computer.state === 'running' && phoneControls.size > 0)
  }
  async function ensureFilesReady(): Promise<void> {
    await upgradeWork
    if (upgrade?.state === 'failed') throw new ComputerConflictError(upgrade.message ?? 'Caboose components could not be updated')
    const warning = controller.componentsWarning?.()
    if (warning) throw new ComputerConflictError(warning)
  }
  function managementStatus() {
    const desired = settings.get()
    const active = controller.activeResources()
    const tasks = agents.list()
    return {
      state: computer.state, settings: desired, limits: settings.limits, activeResources: active,
      restartRequired: controller.hasSavedState() && (!active || active.memoryMb !== desired.memoryMb || active.vcpus !== desired.vcpus),
      clients: { display: sockets.size - controls.size, control: controls.size },
      tasks: { running: tasks.filter(task => task.status === 'running').length, paused: tasks.filter(task => task.status === 'paused').length },
      capabilities: { restart: typeof controller.restart === 'function', push: !!push },
      upgrade,
      lastError: computer.lastError ?? controller.lastError?.() ?? null,
    }
  }
  /**
   * Long guest work (an agent install can take minutes) holds a lease so the computer is not
   * parked under it, without queueing every other request behind it as computer.run would.
   */
  async function leased<R>(work: () => Promise<R>): Promise<R> {
    if (computer.state !== 'running') throw new ComputerConflictError('Computer is not running')
    const release = computer.acquire()
    try { return await work() } finally { release() }
  }
  function broadcastSettings(): void { broadcast({ type: 'computer.settings', computer: managementStatus() }) }
  function closeSockets(): void { for (const socket of sockets) socket.terminate() }
  computer.subscribe(state => {
    broadcast({ type: 'computer.state', state })
    if (state === 'running' && controller.componentsMode && !upgrading) {
      const guest = controller.guest()
      if (guest) {
        upgrading = true
        const release = computer.acquire()
        upgradeWork = upgradeComponents(guest, controller.componentsMode, publishUpgrade).finally(() => { upgrading = false; release() })
      }
    }
    if (state === 'running') agents.resume()
    else { agents.pause(); media.computerStopped() }
    syncMedia()
    syncFiles()
    desktopNotifications.setActive(state === 'running')
    broadcastSettings()
  })
  /** Phones' sockets by phone, so signing a phone out closes what it has open. */
  const phoneSockets = new Map<WebSocket, string>()

  async function handle(request: IncomingMessage, response: ServerResponse, path: string, principal: Principal): Promise<unknown> {
    if (request.method === 'POST' && path === '/v1/fs/open') {
      const input = await readJson(request)
      const relative = input.path
      if (typeof relative !== 'string' || !relative || relative.startsWith('/') || relative.split('/').some(part => !part || part === '.' || part === '..' || part.includes('\0'))) {
        throw new AgentInputError('invalid file path')
      }
      if (input.app !== undefined && (typeof input.app !== 'string' || !/^[a-zA-Z0-9._-]+\.desktop$/.test(input.app))) throw new AgentInputError('invalid application id')
      return computer.wakeAndRun(async () => {
        await ensureFilesReady()
        if (!controller.fileService || !controller.guest()) throw new AgentUnavailableError()
        const service = controller.fileService(), url = new URL('/stat', service.url)
        url.searchParams.set('path', relative)
        const checked = await fetch(url, { headers: { authorization: `Bearer ${service.token}` } })
        if (!checked.ok) return json(response, checked.status, { error: 'file unavailable' })
        if (typeof input.app === 'string') await controller.launch(input.app, relative)
        else await openOnDisplay(controller.guest()!, `/home/caboose/${relative}`)
        return json(response, 200, { opened: true })
      })
    }
    if (path.startsWith('/v1/fs/')) {
      return computer.wakeAndRun(async () => {
        await ensureFilesReady()
        if (!controller.fileService) throw new AgentUnavailableError()
        await proxyFiles(controller.fileService(), request, response)
      })
    }
    if (path === '/v1/activities' && request.method === 'POST') {
      if (!activities) return json(response, 503, { error: 'Live Activities unavailable' })
      const body = await readJson(request)
      await activities.store.registerActivity(body)
      void activities.reconcile(body.activityId as string).catch(error => console.error('Live Activity reconciliation failed:', error))
      return json(response, 200, { registered: true })
    }
    if (path === '/v1/activities' && request.method === 'DELETE') {
      if (!activities) return json(response, 503, { error: 'Live Activities unavailable' })
      const body = await readJson(request)
      if (typeof body.activityId !== 'string') throw new SettingsInputError('invalid activityId')
      await activities.store.removeActivity(body.activityId)
      return json(response, 200, { removed: true })
    }
    if (path === '/v1/activities/start-token' && request.method === 'POST') {
      if (!activities) return json(response, 503, { error: 'Live Activities unavailable' })
      await activities.store.registerStarter(await readJson(request), principal.phoneId)
      return json(response, 200, { registered: true })
    }
    if (path === '/v1/activities/start-token' && request.method === 'DELETE') {
      if (!activities) return json(response, 503, { error: 'Live Activities unavailable' })
      const body = await readJson(request)
      if (typeof body.deviceId !== 'string') throw new SettingsInputError('invalid deviceId')
      await activities.store.removeStarter(body.deviceId)
      return json(response, 200, { removed: true })
    }
    if (path === '/v1/jobs/activity' && request.method === 'POST') {
      if (!activities) return json(response, 503, { error: 'Live Activities unavailable' })
      const body = await readJson(request)
      if (typeof body.start !== 'boolean') throw new SettingsInputError('start must be boolean')
      const job = parseJob(body.job)
      await activities.job(job, body.start, foregroundClients.size > 0)
      return json(response, 200, { sent: true })
    }
    if (path === '/v1/devices/push' && request.method === 'POST') {
      if (!push) return json(response, 503, { error: 'push unavailable' })
      await push.devices.register(await readJson(request), principal.phoneId)
      return json(response, 200, { registered: true })
    }
    if (path === '/v1/devices/push' && request.method === 'GET') {
      if (!push) return json(response, 503, { error: 'push unavailable' })
      return json(response, 200, { devices: push.devices.summaries() })
    }
    const pushDevice = /^\/v1\/devices\/push\/([^/]+)$/.exec(path)
    if (pushDevice?.[1] && request.method === 'DELETE') {
      if (!push) return json(response, 503, { error: 'push unavailable' })
      if (!await push.devices.removeById(decodeURIComponent(pushDevice[1]))) throw new AgentNotFoundError('device not found')
      return json(response, 200, { removed: true })
    }
    if (path === '/v1/devices/push' && request.method === 'DELETE') {
      if (!push) return json(response, 503, { error: 'push unavailable' })
      await push.devices.remove((await readJson(request)).token)
      return json(response, 200, { removed: true })
    }
    if (request.method === 'GET' && path === '/v1/computer') return json(response, 200, managementStatus())
    if (request.method === 'PATCH' && path === '/v1/computer/settings') {
      const input = await readJson(request)
      if ('defaultAgent' in input) await catalog.ensureKnown(input.defaultAgent)
      const updated = await settings.update(input)
      computer.setIdleMs(updated.idleMs)
      broadcastSettings()
      return json(response, 200, managementStatus())
    }
    if (request.method === 'POST' && path === '/v1/computer/restart') {
      if (upgrading) throw new ComputerConflictError('Caboose components are updating')
      if (appCatalog.busy || craftBusy) throw new ComputerConflictError('An application operation is in progress')
      const body = await readJson(request)
      if (body.confirm !== true) throw new SettingsInputError('Restart closes apps and discards unsaved work; confirm must be true')
      await computer.restart(async () => {
        closeSockets()
        // The cold boot stops every task. Do not wait for per-task cancellation:
        // an unresponsive guest must not prevent its own restart.
      })
      agents.computerRestarted()
      broadcastSettings()
      return json(response, 200, managementStatus())
    }
    if (request.method === 'POST' && path === '/v1/session') {
      const session = await computer.wake()
      return json(response, 200, { ...session, computer: { ...session.computer, name: settings.get().name } })
    }
    if (request.method === 'POST' && path === '/v1/session/park') {
      if (upgrading) throw new ComputerConflictError('Caboose components are updating')
      if (appCatalog.busy || craftBusy) throw new ComputerConflictError('An application operation is in progress')
      await computer.park(closeSockets)
      return json(response, 200, { state: computer.state })
    }
    if (request.method === 'GET' && path === '/v1/catalog') return json(response, 200, await appCatalog.list())
    const craftRun = /^\/v1\/catalog\/([^/]+)\/run$/.exec(path)
    if (request.method === 'POST' && craftRun?.[1]) {
      const id = decodeURIComponent(craftRun[1])
      const input = parseCraftRequest(id, await readJson(request))
      if (craftJobs.has(input.job)) throw new AgentConflictError('Craft job is already running')
      if (appCatalog.busy) throw new AgentConflictError('An application install is in progress')
      craftJobs.add(input.job)
      craftBusy++
      try {
        await computer.wake()
        return await leased(async () => {
          const listing = await appCatalog.list()
          const app = listing.apps.find(item => item.id === id)
          if (!app?.installedVersion) throw new AgentNotFoundError('Craft app is not installed')
          const job = { id: input.job, kind: 'craft', title: app.name, status: 'running' as const, detail: 'Processing files' }
          const publish = (state: typeof job | { id: string; kind: string; title: string; status: 'succeeded' | 'failed'; detail: string }, start: boolean) => {
            broadcast({ type: 'job.progress', job: state })
            if (activities) void activities.job(state, start, false).catch(error => console.error('Craft activity failed:', error))
          }
          publish(job, true)
          try {
            const { outputs, warnings } = await runCraft(controller.guest(), id, input, true)
            publish({ ...job, status: 'succeeded', detail: 'Finished' }, false)
            return json(response, 200, { job: input.job, outputs, warnings })
          } catch (error) {
            publish({ ...job, status: 'failed', detail: error instanceof Error ? error.message.slice(0, 500) : 'Failed' }, false)
            throw error
          }
        })
      } finally { craftBusy--; craftJobs.delete(input.job) }
    }
    const packInstall = /^\/v1\/catalog\/packs\/([^/]+)\/install$/.exec(path)
    if (request.method === 'POST' && packInstall?.[1]) { if (craftBusy) throw new ComputerConflictError('A Craft job is running'); if (computer.state !== 'running') throw new ComputerConflictError('Computer is not running'); if (upgrading) throw new ComputerConflictError('Caboose components are updating'); appCatalog.startPack(decodeURIComponent(packInstall[1])); return json(response, 202, { accepted: true }) }
    const appAction = /^\/v1\/catalog\/([^/]+)\/(install|update|rollback)$/.exec(path)
    if (request.method === 'POST' && appAction?.[1]) { if (craftBusy) throw new ComputerConflictError('A Craft job is running'); if (computer.state !== 'running') throw new ComputerConflictError('Computer is not running'); if (upgrading) throw new ComputerConflictError('Caboose components are updating'); appCatalog.start(decodeURIComponent(appAction[1]), appAction[2] as 'install' | 'update' | 'rollback'); return json(response, 202, { accepted: true }) }
    const removeApp = /^\/v1\/catalog\/([^/]+)$/.exec(path)
    if (request.method === 'DELETE' && removeApp?.[1]) { if (craftBusy) throw new ComputerConflictError('A Craft job is running'); if (computer.state !== 'running') throw new ComputerConflictError('Computer is not running'); if (upgrading) throw new ComputerConflictError('Caboose components are updating'); appCatalog.start(decodeURIComponent(removeApp[1]), 'remove'); return json(response, 202, { accepted: true }) }
    if (request.method === 'GET' && path === '/v1/apps') {
      return json(response, 200, await computer.run(() => controller.apps()))
    }
    const match = /^\/v1\/apps\/([^/]+)\/launch$/.exec(path)
    if (request.method === 'POST' && match?.[1]) {
      await computer.run(() => controller.launch(decodeURIComponent(match[1]!)))
      return json(response, 200, { launched: true })
    }
    if (request.method === 'GET' && path === '/v1/agents') return json(response, 200, await catalog.list())
    const agentAction = /^\/v1\/agents\/([^/]+)\/(install|sign-in)$/.exec(path)
    if (request.method === 'POST' && agentAction?.[1]) {
      const id = decodeURIComponent(agentAction[1])
      const input = await readJson(request)
      if (agentAction[2] === 'install') {
        const agent = await leased(() => catalog.install(id))
        broadcastSettings()
        return json(response, 200, { agent })
      }
      return json(response, 200, await leased(() => catalog.signIn(id, input)))
    }
    const agentEnv = /^\/v1\/agents\/([^/]+)\/env$/.exec(path)
    if (request.method === 'PUT' && agentEnv?.[1]) {
      const input = await readJson(request)
      return json(response, 200, await leased(() => catalog.setEnv(decodeURIComponent(agentEnv[1]!), input)))
    }
    if (path === '/v1/agent/tasks' && request.method === 'GET') return json(response, 200, agents.list())
    if (path === '/v1/agent/tasks' && request.method === 'POST') {
      const input = await readJson(request, TASK_BODY_LIMIT)
      const task = await computer.run(() => agents.start(input))
      return json(response, 200, { id: task.id })
    }
    const reply = /^\/v1\/agent\/tasks\/([0-9a-f-]{36})\/reply$/.exec(path)
    if (request.method === 'POST' && reply?.[1]) {
      const input = await readJson(request)
      return json(response, 200, { task: await computer.run(() => agents.reply(reply[1]!, input)) })
    }
    const approval = /^\/v1\/agent\/tasks\/([0-9a-f-]{36})\/approvals\/([0-9a-f-]{36})$/.exec(path)
    if (request.method === 'POST' && approval?.[1] && approval[2]) {
      const input = await readJson(request)
      return json(response, 200, { resolved: await computer.run(() => agents.resolveApproval(approval[1]!, approval[2]!, input)) })
    }
    const cancel = /^\/v1\/agent\/tasks\/([0-9a-f-]{36})\/cancel$/.exec(path)
    if (request.method === 'POST' && cancel?.[1]) {
      return json(response, 200, { cancelled: await computer.run(() => agents.cancel(cancel[1]!)) })
    }
    const hold = /^\/v1\/agent\/tasks\/([0-9a-f-]{36})\/(pause|resume)$/.exec(path)
    if (request.method === 'POST' && hold?.[1]) {
      const id = hold[1]
      return json(response, 200, await computer.run(async () => hold[2] === 'pause' ? { paused: await agents.pauseTask(id) } : { resumed: await agents.resumeTask(id) }))
    }
    if (request.method === 'GET' && path === '/v1/media') {
      return json(response, 200, { media: await media.read(computer.state === 'running') })
    }
    const control = /^\/v1\/media\/([^/]+)\/control$/.exec(path)
    if (request.method === 'POST' && control?.[1]) {
      const command = parseMediaCommand(control[1], await readJson(request))
      await computer.run(() => media.send(command))
      return json(response, 200, { sent: true })
    }
    if (request.method === 'GET' && path === '/v1/screen/elements') return json(response, 200, await computer.run(() => screenElements(controller.guest())))
    const screen = { '/v1/screen/act': screenAct, '/v1/screen/type': screenType, '/v1/screen/keys': screenKeys }[path]
    if (request.method === 'POST' && screen) {
      const input = await readJson(request)
      return json(response, 200, await computer.run(() => screen(controller.guest(), input)))
    }
    const phoneFile = /^\/v1\/phone\/files\/([^/]+)$/.exec(path)
    if (request.method === 'GET' && phoneFile?.[1]) return json(response, 200, await leased(() => readPhoneFile(controller.guest(), phoneFile[1]!)))
    if (request.method === 'POST' && path === '/v1/files') {
      const input = await readJson(request, Number.MAX_SAFE_INTEGER)
      if (typeof input.name !== 'string' || !input.name.trim()) throw new AgentInputError('name is required')
      if (input.open !== undefined && typeof input.open !== 'boolean') throw new AgentInputError('open must be a boolean')
      const data = decodeBase64(input.data, 'data')
      return json(response, 200, await computer.wakeAndRun(async () => {
        await ensureFilesReady()
        if (!controller.fileService || !controller.guest()) throw new AgentUnavailableError()
        const service = controller.fileService()
        const headers = { authorization: `Bearer ${service.token}` }
        const mkdir = await fetch(`${service.url}/mkdir?path=Downloads`, { method: 'POST', headers })
        if (!mkdir.ok && mkdir.status !== 409) throw new Error('Could not create Downloads')
        const name = sanitizeFileName(input.name), { stem, ext } = splitName(name)
        for (let n = 1; ; n++) {
          const target = n === 1 ? name : `${stem} (${n})${ext}`
          const url = new URL('/content', service.url)
          url.searchParams.set('path', `Downloads/${target}`)
          const saved = await fetch(url, { method: 'PUT', headers: { ...headers, 'if-none-match': '*', 'content-length': String(data.length) }, body: new Uint8Array(data) })
          if (saved.status === 412) continue
          if (!saved.ok) throw new Error('Could not save file in Downloads')
          const path = `${DOWNLOADS}/${target}`
          if (input.open === true) await openOnDisplay(controller.guest()!, path)
          return { path }
        }
      }))
    }
    if (request.method === 'POST' && path === '/v1/open') {
      const input = await readJson(request)
      return json(response, 200, await computer.run(() => openUrl(controller.guest(), input)))
    }
    return NOT_FOUND
  }

  /** Byte relay between a client and a guest caboose-display, with backpressure in both directions. */
  function relay(client: WebSocket, upstreamUrl: string): void {
    const upstream = new WebSocket(upstreamUrl, 'binary', { maxPayload: 16 * 1024 * 1024, handshakeTimeout: 10_000 })
    // Pause the sender until the destination flushes, bounding queued data.
    client.pause()
    upstream.on('open', () => client.resume())
    function forward(source: WebSocket, destination: WebSocket): void {
      source.on('message', (data, isBinary) => {
        if (!isBinary || destination.readyState !== WebSocket.OPEN) { source.close(1003, 'binary required'); return }
        source.pause()
        destination.send(data, { binary: true }, error => {
          if (error) source.terminate()
          else if (source.readyState === WebSocket.OPEN) source.resume()
        })
      })
    }
    forward(client, upstream); forward(upstream, client)
    upstream.on('error', () => { client.terminate(); upstream.terminate() })
    upstream.on('close', () => client.close())
    client.once('close', () => upstream.terminate())
  }

  function connect(request: IncomingMessage, socket: Duplex, head: Buffer, url: URL, path: string, principal: Principal): void {
    if (!computer.acceptsConnections) { socket.end('HTTP/1.1 409 Conflict\r\nConnection: close\r\n\r\n'); return }
    const offered = request.headers['sec-websocket-protocol']?.split(',').map(value => value.trim()) ?? []
    if (path === '/v1/display' && !offered.includes('binary')) { socket.end('HTTP/1.1 400 Bad Request\r\nConnection: close\r\n\r\n'); return }
    const release = computer.acquire()
    socket.once('close', release)
    try {
      wss.handleUpgrade(request, socket, head, client => {
        sockets.add(client)
        if (principal.phoneId) phoneSockets.set(client, principal.phoneId)
        if (path === '/v1/control') {
          controls.add(client)
          if (url.searchParams.get('foreground') === '1') foregroundClients.add(client)
          if (url.searchParams.get('phone') === '1') phoneControls.add(client)
        }
        syncMedia()
        syncFiles()
        client.on('error', () => client.terminate())
        client.once('close', () => { sockets.delete(client); phoneSockets.delete(client); controls.delete(client); foregroundClients.delete(client); phoneControls.delete(client); release(); syncMedia(); syncFiles() })
        if (path === '/v1/control') {
          client.send(JSON.stringify({ type: 'computer.state', state: computer.state }))
          client.send(JSON.stringify({ type: 'computer.settings', computer: managementStatus() }))
          const playing = media.watched()
          if (playing) client.send(JSON.stringify({ type: 'media.playing', media: playing }))
          return
        }
        if (url.searchParams.get('seat') === 'agent') {
          // The agent seat starts on demand; hold the client until it is up.
          client.pause()
          controller.ensureAgentSeat().then(
            () => { if (client.readyState === WebSocket.OPEN) relay(client, controller.agentDisplayUrl) },
            () => client.close(1011, 'agent seat unavailable'))
          return
        }
        relay(client, controller.displayUrl)
      })
    } catch { release(); socket.destroy() }
  }

  function disconnectPhone(phoneId: string): void {
    for (const [socket, phone] of phoneSockets) if (phone === phoneId) socket.terminate()
  }

  async function shutdown(): Promise<void> {
    await upgradeWork
    await computer.park(closeSockets)
  }

  /** Deletes the computer once queued work is done: its sockets close, its tasks end and its disk goes. */
  async function destroy(): Promise<void> {
    await upgradeWork
    await computer.retire(async () => {
      closeSockets()
      agents.computerRestarted()
      if (!controller.destroy) throw new ComputerConflictError('This runtime cannot delete a computer')
      await controller.destroy()
    })
  }

  return { id, computer, settings, push, activities, managementStatus, handle, connect, disconnectPhone, shutdown, destroy, busy: () => upgrading || appCatalog.busy || craftBusy > 0 }
}

type ComputerRuntime = ReturnType<typeof createComputerRuntime>

/**
 * How a host makes and keeps computers beyond the owner's. Without one, a host serves only
 * the owner's computer (as the tests do) and cannot make more.
 */
export interface Fleet {
  computers: ComputerRegistry
  phones: PhoneTokens
  /** Initial resources for a new computer, before the owner's choices. */
  defaults: Pick<ComputerSettings, 'memoryMb' | 'vcpus' | 'idleMs'>
  /** The pieces of a computer, new (with its initial settings) or existing. */
  open(record: ComputerRecord, initial?: ComputerSettings): Promise<ComputerPieces>
  /** Computers other than the owner's that already exist, opened at startup. */
  existing?: Array<{ record: ComputerRecord; pieces: ComputerPieces }>
  /** How many may run at once, or null when the runtime sets no limit. */
  maxRunning: number | null
}

export function createCabooseServer(options: ComputerPieces & {
  token: string; webRoot?: string
  /** The ACP agent registry; defaults to the public registry, cached in memory only. */
  registry?: AgentRegistry
  /** How long a task's runner keeps its agent after a turn, waiting for a reply. */
  agentIdleMs?: number
  /** How this host was started, for `GET /v1/host`. */
  host?: HostInfo
  /** The machine's memory, CPUs and disk, for `GET /v1/health`. */
  machine?: () => Promise<MachineResources>
  fleet?: Fleet
}) {
  const shared = { registry: options.registry ?? new AgentRegistry(), ...(options.agentIdleMs !== undefined ? { agentIdleMs: options.agentIdleMs } : {}) }
  const owner = createComputerRuntime(OWNER_COMPUTER, options, shared)
  const runtimes = new Map<string, ComputerRuntime>([[OWNER_COMPUTER, owner]])
  for (const { record, pieces } of options.fleet?.existing ?? []) runtimes.set(record.id, createComputerRuntime(record.id, pieces, shared))
  const records = () => options.fleet?.computers.list() ?? [{ id: OWNER_COMPUTER, slot: 0, createdAt: null }]
  const describe = (runtime: ComputerRuntime) => ({ id: runtime.id, createdAt: records().find(c => c.id === runtime.id)?.createdAt ?? null, ...runtime.managementStatus() })
  const deleting = new Set<string>()

  function principalOf(request: IncomingMessage): Principal | undefined {
    if (authenticate(request.headers.authorization, options.token)) return { kind: 'owner' }
    const header = request.headers.authorization
    if (!header?.startsWith('Bearer ') || !options.fleet) return undefined
    const phone = options.fleet.phones.resolve(header.slice(7))
    return phone && runtimes.has(phone.computerId) ? { kind: 'phone', ...phone } : undefined
  }

  /** The computer a path names (`/v1/computers/<id>/…`, owner only) or the principal's own, with the path it serves. */
  function target(path: string, principal: Principal): { runtime: ComputerRuntime; path: string } | 'forbidden' | undefined {
    const scoped = /^\/v1\/computers\/([^/]+)(\/.+)$/.exec(path)
    if (scoped) {
      if (principal.kind !== 'owner') return 'forbidden'
      const runtime = runtimes.get(decodeURIComponent(scoped[1]!))
      return runtime && !deleting.has(runtime.id) ? { runtime, path: `/v1${scoped[2]}` } : undefined
    }
    const runtime = runtimes.get(principal.kind === 'phone' ? principal.computerId : OWNER_COMPUTER)
    return runtime ? { runtime, path } : undefined
  }

  async function createComputer(input: Record<string, unknown>): Promise<ComputerRuntime> {
    const fleet = options.fleet
    if (!fleet) throw new ComputerConflictError('This host serves one computer')
    if (!('name' in input)) throw new SettingsInputError('name is required')
    if ('defaultAgent' in input) throw new SettingsInputError('Unknown setting: defaultAgent')
    const initial = updateSettings({ name: 'Computer', defaultAgent: null, ...fleet.defaults }, input, settingsLimits())
    const record = await fleet.computers.create()
    try {
      const runtime = createComputerRuntime(record.id, await fleet.open(record, initial), shared)
      runtimes.set(record.id, runtime)
      return runtime
    } catch (error) {
      await fleet.computers.remove(record.id).catch(() => {})
      throw error
    }
  }

  async function deleteComputer(runtime: ComputerRuntime): Promise<void> {
    const fleet = options.fleet
    if (runtime.id === OWNER_COMPUTER || !fleet) throw new ComputerConflictError("The owner's computer cannot be deleted")
    if (deleting.has(runtime.id)) throw new ComputerConflictError('Computer is already being deleted')
    if (runtime.busy()) throw new ComputerConflictError('An operation is in progress on this computer')
    deleting.add(runtime.id)
    try {
      await runtime.destroy()
      await fleet.phones.revokeComputer(runtime.id)
      await fleet.computers.remove(runtime.id)
      await rm(fleet.computers.dataDir(runtime.id), { recursive: true, force: true })
      runtimes.delete(runtime.id)
    } finally { deleting.delete(runtime.id) }
  }

  const server = createServer((request, response) => {
    void (async () => {
      const path = new URL(request.url ?? '/', 'http://localhost').pathname
      if (path !== '/v1' && !path.startsWith('/v1/')) {
        if (options.webRoot) return serveWeb(request, response, options.webRoot, path)
        return json(response, 404, { error: 'not found' })
      }
      const principal = principalOf(request)
      if (!principal) return json(response, 401, { error: 'unauthorized' })
      const ownerOnly = path === '/v1/health' || path === '/v1/host' || path === '/v1/computers' || /^\/v1\/computers\/[^/]+(?:\/phones(?:\/[^/]+)?)?$/.test(path)
      if (ownerOnly && principal.kind !== 'owner') return json(response, 403, { error: 'forbidden' })
      if (request.method === 'GET' && path === '/v1/health') {
        return json(response, 200, { ...(options.controller.stats() as object), ...(options.machine ? { machine: await options.machine() } : {}) })
      }
      if (request.method === 'GET' && path === '/v1/host' && options.host) return json(response, 200, options.host)
      if (path === '/v1/computers' && request.method === 'GET') {
        return json(response, 200, {
          computers: [...runtimes.values()].filter(r => !deleting.has(r.id)).map(describe),
          canCreate: !!options.fleet, limits: { computers: options.fleet ? MAX_SLOTS : 1, running: options.fleet?.maxRunning ?? null },
        })
      }
      if (path === '/v1/computers' && request.method === 'POST') return json(response, 201, describe(await createComputer(await readJson(request))))
      const computerPath = /^\/v1\/computers\/([^/]+)(?:\/phones(?:\/([^/]+))?)?$/.exec(path)
      if (computerPath?.[1]) {
        const runtime = runtimes.get(decodeURIComponent(computerPath[1]))
        if (!runtime || deleting.has(runtime.id)) return json(response, 404, { error: 'computer not found' })
        const phones = path.slice(`/v1/computers/${computerPath[1]}`.length)
        if (!phones && request.method === 'GET') return json(response, 200, describe(runtime))
        if (!phones && request.method === 'DELETE') {
          if ((await readJson(request)).confirm !== true) throw new SettingsInputError('Deleting a computer deletes its disk and everything on it; confirm must be true')
          await deleteComputer(runtime)
          return json(response, 200, { deleted: true })
        }
        const fleet = options.fleet
        if (phones === '/phones' && request.method === 'GET') return json(response, 200, { phones: fleet?.phones.list(runtime.id) ?? [] })
        if (phones === '/phones' && request.method === 'POST') {
          if (!fleet) throw new ComputerConflictError('This host has no phone sign-ins')
          return json(response, 201, await fleet.phones.mint(runtime.id, (await readJson(request)).name))
        }
        if (computerPath[2] && request.method === 'DELETE') {
          const phoneId = decodeURIComponent(computerPath[2])
          if (!fleet || !await fleet.phones.revoke(runtime.id, phoneId)) throw new AgentNotFoundError('phone not found')
          runtime.disconnectPhone(phoneId)
          await runtime.push?.devices.removeByPhone(phoneId)
          await runtime.activities?.store.removeByPhone(phoneId)
          return json(response, 200, { revoked: true })
        }
        return json(response, 404, { error: 'not found' })
      }
      const routed = target(path, principal)
      if (routed === 'forbidden') return json(response, 403, { error: 'forbidden' })
      if (!routed) return json(response, 404, { error: 'computer not found' })
      if (await routed.runtime.handle(request, response, routed.path, principal) === NOT_FOUND) return json(response, 404, { error: 'not found' })
    })().catch(error => {
      if (error instanceof AgentInputError || error instanceof SettingsInputError || error instanceof MediaInputError) return json(response, 400, { error: error.message })
      if (error instanceof AgentNotFoundError || error instanceof ScreenElementGoneError) return json(response, 404, { error: error.message })
      if (error instanceof AgentUnavailableError || error instanceof DisplayNotReadyError || error instanceof AgentConflictError || error instanceof ComputerConflictError || error instanceof ComputerCapacityError) return json(response, 409, { error: error.message })
      if (error instanceof AgentOperationError) return json(response, 502, { error: error.message })
      console.error('Caboose request failed:', error)
      if (!response.headersSent) json(response, 500, { error: 'computer operation failed' })
      else response.destroy()
    })
  })

  server.on('upgrade', (request, socket, head) => {
    const url = new URL(request.url ?? '/', 'http://localhost')
    const principal = principalOf(request)
    if (!principal) { socket.end('HTTP/1.1 401 Unauthorized\r\nConnection: close\r\n\r\n'); return }
    const routed = target(url.pathname, principal)
    if (routed === 'forbidden') { socket.end('HTTP/1.1 403 Forbidden\r\nConnection: close\r\n\r\n'); return }
    if (!routed || (routed.path !== '/v1/display' && routed.path !== '/v1/control')) { socket.end('HTTP/1.1 404 Not Found\r\nConnection: close\r\n\r\n'); return }
    routed.runtime.connect(request, socket, head, url, routed.path, principal)
  })

  async function shutdown(): Promise<void> {
    await Promise.all([...runtimes.values()].map(runtime => runtime.shutdown().catch(error => console.error(`Computer ${runtime.id} did not park:`, error))))
    await new Promise<void>((resolve, reject) => server.close(error => error ? reject(error) : resolve()))
  }
  return { server, computer: owner.computer, shutdown }
}
