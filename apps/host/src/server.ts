import { UsageHistory } from './computer-usage.js'
import type { UsageCounters, ComputerStorage as UsageStorage } from '../../../packages/capacity/types.js'
import { CapacitySampler, capacityFor } from './capacity.js'
import { recoveryRoute } from './recovery.js'
import { AccountSocketFence } from './identity/socket-fence.js'
import { computerSizes, expandSize } from './sizes.js'
import { createHash } from 'node:crypto'
import { upgradeComponents, type ComponentsMode, type UpgradeStatus } from './components.js'
import { parseCraftRequest, runCraft } from './craft-jobs.js'
import { proxyFiles, proxyWebview, type FileService } from './fs-proxy.js'
import type { ParkedFilesView } from './parked-files-store.js'
import { serveParkedFiles } from './parked-files-reader.js'
import { agentJob, parseJob, type ActivityService } from './activities.js'
import { rm } from 'node:fs/promises'
import { createServer, type IncomingMessage, type ServerResponse } from 'node:http'
import type { Duplex } from 'node:stream'
import { WebSocket, WebSocketServer } from 'ws'
import { authenticate } from './auth.js'
import { NOT_FOUND, json, noContent, readJson } from './http.js'
import { createDesktopShortcut, parseAppLaunch, type AppAction } from './guest-apps.js'
import { AgentCatalog } from './agent-catalog.js'
import { AppCatalog, craftMcpServers } from './app-catalog.js'
import type { Architecture } from './app-catalog-data.js'
import type { FlathubIndex } from './flathub.js'
import { McpLibrary } from './mcp-library.js'
import { replaceGuestFile } from './guest-private-file.js'
import type { SmitheryCatalog } from './smithery.js'
import type { CraftReleases } from './releases.js'
import type { RuntimeDepot } from './depot.js'
import { AgentConflictError, AgentInputError, AgentNotFoundError, AgentOperationError, AgentTasks, AgentUnavailableError, type AgentGuest } from './agents.js'
import { openUrl, openOnDisplay, decodeBase64, sanitizeFileName, splitName, DOWNLOADS } from './files.js'
import { ComputerConflictError, ComputerLifecycle, type ComputerDriver } from './lifecycle.js'
import { tieredController, type SnapshotTierOptions } from './snapshot-tier-controller.js'
import { HomeOwnership } from './home.js'
import { MediaHandoff, MediaInputError, parseMediaCommand } from './media.js'
import { BridgeInputError, BridgeRateLimitError, BridgeRelay, LocationShare, parseAppearance, parseLocation, type BridgeEvent } from './bridge.js'
import { NowPlaying, NowPlayingInputError, parseNowPlayingCommand } from './now-playing.js'
import { AgentRegistry } from './registry.js'
import { PhoneHandoff, readPhoneFile } from './phone.js'
import { SettingsInputError, settingsLimits, updateSettings, type ComputerSettings, type SettingsStore } from './settings.js'
import { MAX_SLOTS } from './network.js'
import { ComputerCapacityError, OWNER_COMPUTER, PairingCodes, PairingRateLimitError, personName, phoneName, type ComputerAssignment, type ComputerRecord, type ComputerRegistry, type PhoneTokens } from './computers.js'
import { toNodeHandler } from 'better-auth/node'
import { IdentityConflictError, IdentityInputError, IdentityNotFoundError, type AdminPrincipal, type Identity } from './identity/service.js'
import { SignInThrottle, administers, isSignInAttempt, tenancyRoute, tenantUsage, webHeaders, type TenancyContext } from './identity/routes.js'
import type { DisplayProtocol } from './config.js'
import { DisplayNotReadyError } from './display.js'
import type { ComputerResources } from './driver.js'
import { serveWeb } from './static.js'
import type { ComputerStorage } from './storage.js'
import type { SharedStorageStatus } from './shared-storage.js'
import type { RestoredDisk } from './restore-journal.js'
import { ReachUnavailableError, type ReachService } from './reach.js'
import { DesktopNotifications } from './desktop-notifications.js'
import type { PushService } from './push.js'
import type { HostInfo, MachineResources } from './host-info.js'
import type { AgentEvent } from './agents.js'
import { ScreenElementGoneError, screenAct, screenElements, screenKeys, screenType } from './screen.js'
import { agentAutomation } from './agent-automation.js'
import { type AgentToolJournal, type ToolDispatcher } from './agent-tools-journal.js'
import { type AgentRoutines, type RoutineOptions, type RoutineTask } from './agent-routines.js'
import { AgentProfiles, prepareProfileStart } from './agent-profiles.js'
import { MAX_TERMINALS, TerminalGoneError, TerminalServiceError, guestTerminalUrl, hangupTerminal, listTerminalSessions, parseTerminalQuery, relayTerminal, type TerminalQuery, type TerminalService } from './terminal.js'

export interface App { id: string; name: string; icon: string; categories: string[]; exec: string; actions: AppAction[]; startupWMClass?: string | null }
export interface Session { state: string; display: { path: string; token: string; protocol: DisplayProtocol }; computer: { name: string; image: string; memoryMb: number; vcpus: number } }
export interface Controller extends ComputerDriver<Session> {
  /** Install the lifecycle fence used for optional parked Files publication. */
  bindParkedFilesGuard?(guard: () => () => boolean): void
  parkedFilesView?(): Promise<ParkedFilesView | undefined>
  componentsMode?: ComponentsMode
  componentsWarning?(): string | undefined
  usageCounters?(): Promise<UsageCounters>
  usageStorage?(): Promise<UsageStorage>
  stats(): unknown
  apps(): Promise<App[]>
  /** Starts an entry, opening a home-relative file with it or running one of its actions. */
  launch(id: string, path?: string, action?: string): Promise<void>
  /** The owner's display in the guest: caboose-display's WebSocket. */
  displayUrl: string
  /** The agent seat's caboose-display, started on demand by ensureAgentSeat. */
  agentDisplayUrl: string
  ensureAgentSeat(): Promise<void>
  /** Root command runner in the running computer, or undefined while parked. */
  guest(): AgentGuest | undefined
  fileService?(): FileService
  /** The guest's caboose-terminal, once the computer has woken. */
  terminalService?(): TerminalService
  activeResources(): ComputerResources | null
  hasSavedState(): boolean
  lastError?(): string | null
  /** Deletes the computer and its disk; only when the computer itself is deleted. */
  destroy?(): Promise<void>
  /** Refuse a restored disk this computer cannot boot, before anything changes. */
  checkDiskReplacement?(replacement: RestoredDisk): Promise<void>
  /** Install a restored disk (and its image binding), journaled, during the next restart. */
  replaceDiskOnRestart?(replacement: RestoredDisk): void
}

/** Body limits: base64 inflates by a third, plus room for the JSON around it. */
const TASK_BODY_LIMIT = 15 * 1024 * 1024


/** Who a request is from: the owner (the host's own token), or a phone signed in to one computer. */
/** Who a request is from: the owner token, an administrator signed in to the console, or a phone signed in to one computer. */
export type Principal =
  | { kind: 'owner'; phoneId?: undefined }
  | (AdminPrincipal & { phoneId?: undefined })
  | { kind: 'phone'; phoneId: string; computerId: string }

/** What one computer is made of: its settings, its runtime, and the notifications its phones get. */
export interface ComputerPieces { /** Phone backups and shared storage (storage.ts). */ storage?: ComputerStorage; snapshotPath?: string; snapshotTier?: SnapshotTierOptions; /** The computer's MCP Library record (mcp-library.json), private to the host. */ mcpLibraryFile?: string; prepareKeyring?: () => Promise<void>; settings: SettingsStore; controller: Controller; push?: PushService; activities?: ActivityService; profiles?: AgentProfiles; openRoutines?: (options: RoutineOptions) => Promise<AgentRoutines>; openToolJournal?: (dispatch: ToolDispatcher) => Promise<AgentToolJournal> }


/**
 * Everything one computer serves: its lifecycle and leases, sockets and display relay, agents,
 * catalog, files, media, and the push and Live Activity registrations of its phones.
 */
/** Checks a computer may run, or be given these resources, before it does; throws when not. */
type Admission = (id: string, next?: Pick<ComputerSettings, 'memoryMb' | 'vcpus'>) => Promise<void>

/** A controller whose wakes are admitted first. */
export function withAdmission(controller: Controller, admit: () => Promise<void>): Controller {
  const gated = Object.create(controller) as Controller
  gated.wake = async mode => {
    await admit()
    return controller.wake(mode)
  }
  return gated
}

/** The Library's host-wide parts, shared by every computer. */
export interface Library { flathub?: FlathubIndex; releases?: CraftReleases; depot?: RuntimeDepot; arch?: Architecture; mcp?: { catalog: SmitheryCatalog; hostId: string; request?: import('./smithery.js').Requester } }

function createComputerRuntime(id: string, pieces: ComputerPieces, shared: { registry: AgentRegistry; agentIdleMs?: number; freezeParkMs?: number; admit?: Admission; library?: Library; gpuEnabled: boolean; validateSize: (input: Record<string, unknown>) => Promise<void> }) {
  const { settings, push, activities } = pieces
  const admit = shared.admit
  const tiering = pieces.snapshotPath ? tieredController(pieces.controller, pieces.snapshotPath, pieces.snapshotTier) : undefined
  const tiered = tiering?.controller ?? pieces.controller
  const controller = admit ? withAdmission(tiered, () => admit(id)) : tiered
  const computer = new ComputerLifecycle(controller, settings.get().idleMs, shared.freezeParkMs)
  controller.bindParkedFilesGuard?.(() => computer.parkingGenerationGuard())
  tiering?.attach(computer)
  pieces.storage?.attach(computer)
  const sockets = new Set<WebSocket>()
  const controls = new Set<WebSocket>()
  const foregroundClients = new Set<WebSocket>()
  const backgroundControls = new Set<WebSocket>()
  const phoneControls = new Set<WebSocket>()
  /** Open terminals by who opened them (a phone, or the owner), for the per-client cap. */
  const terminals = new Map<WebSocket, string>()
  /** Terminal upgrades waiting for a wake, counted against the same cap. */
  const pendingTerminals = new Map<string, number>()
  const wss = new WebSocketServer({ noServer: true, maxPayload: 16 * 1024 * 1024, handleProtocols: protocols => protocols.has('binary') ? 'binary' : false })
  function broadcast(event: unknown): void {
    const message = JSON.stringify(event)
    for (const socket of controls) if (socket.readyState === WebSocket.OPEN) socket.send(message)
  }
  let keyringGeneration = 0
  let keyring: { state: 'preparing' | 'ready' | 'failed'; message?: string } | null = null
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
  const appCatalog = new AppCatalog(() => controller.guest(), broadcast, () => computer.acquire(), { ...shared.library, computer: id })
  const mcp = shared.library?.mcp && pieces.mcpLibraryFile
    ? new McpLibrary({ file: pieces.mcpLibraryFile, tag: `${shared.library.mcp.hostId}/${id}`, catalog: shared.library.mcp.catalog, guest: () => controller.guest(), emit: broadcast, ...(shared.library.mcp.request ? { request: shared.library.mcp.request } : {}),
      // Through the computer's file service, so a token never travels on a command line.
      writeFile: async (relative, data) => {
        const service = controller.fileService?.()
        if (!service) throw new AgentUnavailableError()
        await replaceGuestFile(service, relative, data)
      } })
    : undefined
  // Installed apps update once a day while the computer runs; a parked computer is not woken.
  const autoUpdates = setInterval(() => {
    if (computer.state === 'running' && !upgrading && !craftBusy) void appCatalog.autoUpdate().catch(error => console.error('Automatic app updates failed:', error))
    // The MCP Library's day-long token is replaced well before it ends.
    if (computer.state === 'running' && mcp) {
      const release = computer.acquire()
      void mcp.sync().catch(error => console.error('MCP Library token refresh failed:', error instanceof Error ? error.message : error)).finally(release)
    }
  }, 3600_000)
  autoUpdates.unref()
  let toolsError: string | null = null
  const toolJournalReady: Promise<AgentToolJournal | null> = pieces.openToolJournal && pieces.profiles
    ? pieces.openToolJournal(agentAutomation(pieces.profiles, () => routinesReady, () => broadcast({ type: 'agent.profiles.changed' })))
      .catch(error => { toolsError = error instanceof Error ? error.message : String(error); console.error('Cannot open agent tools:', error); return null })
    : Promise.resolve(null)
  const agents: AgentTasks = new AgentTasks(() => controller.guest(), event => {
    broadcast(event)
    if (push) void push.event(event as AgentEvent, foregroundClients.size > 0).catch(error => console.error('Push event failed:', error))
    const job = agentJob(event as AgentEvent)
    if (job && activities) void activities.job(job, event.type === 'agent.task.started' || event.type === 'agent.task.replied', foregroundClients.size > 0).catch(error => console.error('Live Activity event failed:', error))
  }, () => computer.acquire(), {
    ...(pieces.openToolJournal ? { toolJournal: async () => { const journal = await toolJournalReady; if (!journal) throw new AgentConflictError(toolsError ?? 'Agent tools are unavailable'); return journal } } : {}),
    resolver: catalog, home, craftServers: async () => craftMcpServers((await appCatalog.list()).apps), ...(mcp ? { mcpLibrary: () => mcp.sync(true) } : {}), pollMs: 1000, ensureSeat: () => controller.ensureAgentSeat(), ...(shared.agentIdleMs !== undefined ? { idleMs: shared.agentIdleMs } : {}),
  })
  let routineError: string | null = null
  const routineTask = (task: ReturnType<AgentTasks['list']>[number]): RoutineTask => ({
    status: task.delivery ? 'failed' : task.status === 'running' || task.status === 'paused' ? 'active' : task.status === 'succeeded' ? 'succeeded' : 'failed',
    ...(task.delivery?.message || task.summary ? { detail: task.delivery?.message ?? task.summary } : {}),
  })
  const routinesReady: Promise<AgentRoutines | null> = pieces.openRoutines?.({
    runtime: {
      snapshot: async (profileId, prompt) => {
        if (!pieces.profiles) return null
        let profile
        try { profile = pieces.profiles.get(profileId) } catch (error) { if (error instanceof AgentNotFoundError) return null; throw error }
        if (profile.archived) return null
        const prepared = prepareProfileStart(pieces.profiles, { profileId, prompt })
        return { revision: createHash('sha256').update(JSON.stringify(profile)).digest('hex'), input: { request: prepared.input, profile: prepared.profile } }
      },
      acquire: async () => {
        const release = computer.acquire()
        try { await computer.wake('headless'); await ensureFilesReady(); return release } catch (error) { release(); throw error }
      },
      lookup: async taskId => {
        await agents.restore()
        const task = agents.list().find(task => task.id === taskId)
        return task ? routineTask(task) : null
      },
      start: async (envelope, taskId) => {
        // Only the durable scheduler creates this envelope; public routes accept definitions.
        if (!envelope.request || typeof envelope.request !== 'object' || Array.isArray(envelope.request) || !envelope.profile || typeof envelope.profile !== 'object') throw new AgentInputError('Invalid routine launch envelope')
        return routineTask(await agents.start(envelope.request as Record<string, unknown>, { id: taskId, profile: envelope.profile as import('./agents.js').AgentProfileSnapshot }))
      },
    },
    onChange: () => { routineError = null; broadcast({ type: 'agent.routines.changed' }) },
    onError: error => { routineError = error instanceof Error ? error.message : String(error); console.error('Agent routine error:', error) },
  }).then(routines => { routines.start(); return routines }).catch(error => {
    routineError = error instanceof Error ? error.message : String(error)
    console.error('Cannot open agent routines:', error)
    return null
  }) ?? Promise.resolve(null)
  const desktopNotifications = new DesktopNotifications(() => controller.guest(), event => {
    broadcast({ type: 'notification', ...event })
    if (push) void push.desktop(event, foregroundClients.size > 0).catch(error => console.error('Desktop push failed:', error))
  })
  computer.setBeforeFreeze(async () => {
    await Promise.all([desktopNotifications.quiesce(), agents.drainToolWork(), location.quiesce()])
    // A detached terminal can still run a foreground child. Until the service can prove it
    // idle, keep every extant terminal session resident; an unavailable service fails closed.
    try {
      if (!controller.terminalService?.() || !controller.guest()) return false
      return (await listTerminalSessions(controller.terminalService())).length === 0
    } catch { return false }
  })
  let craftBusy = 0
  const craftJobs = new Set<string>()
  const media = new MediaHandoff(() => controller.guest(), broadcast)
  let fileAnchor: string | undefined
  let filePoll: ReturnType<typeof setInterval> | undefined
  let filePollGeneration = 0
  let pollingFiles: number | undefined
  function syncFiles(): void {
    const active = computer.state === 'running' && controls.size > 0 && controller.fileService
    if (!active) {
      if (filePoll) clearInterval(filePoll)
      filePoll = undefined
      filePollGeneration++
      pollingFiles = undefined
      // Freeze preserves the guest epoch. Keep the last observed anchor for the first
      // poll after thaw, but discard it when the guest or all observers have gone away.
      if (computer.state !== 'frozen' || controls.size === 0) fileAnchor = undefined
      return
    }
    if (filePoll) return
    const poll = async () => {
      if (pollingFiles !== undefined || !controller.fileService || computer.state !== 'running') return
      const generation = filePollGeneration
      pollingFiles = generation
      try {
        const service = controller.fileService()
        const url = new URL('/changes', service.url)
        if (fileAnchor) url.searchParams.set('anchor', fileAnchor)
        const response = await fetch(url, { headers: { authorization: `Bearer ${service.token}` }, signal: AbortSignal.timeout(5000) })
        if (!response.ok) throw new Error('File change feed unavailable')
        const change = await response.json() as { anchor: string; changed: boolean }
        if (generation !== filePollGeneration) return
        if (fileAnchor && change.changed) broadcast({ type: 'fs.changed', anchor: change.anchor })
        fileAnchor = change.anchor
      } catch { /* Retry with the previous anchor so missed changes trigger a rescan. */ }
      finally { if (pollingFiles === generation) pollingFiles = undefined }
    }
    void poll()
    filePoll = setInterval(() => { void poll() }, 1000)
    filePoll.unref()
  }

  const phone = new PhoneHandoff(() => controller.guest(), event => {
    const message = JSON.stringify(event)
    for (const socket of phoneControls) if (socket.readyState === WebSocket.OPEN) socket.send(message)
  })
  /** File chooser requests go to phone sockets only; an answered one is withdrawn from the other phones. */
  const bridge = new BridgeRelay(() => controller.guest(), (event: BridgeEvent, exceptPhone?: string) => {
    const message = JSON.stringify(event)
    for (const socket of phoneControls) {
      if (exceptPhone !== undefined && phoneSockets.get(socket) === exceptPhone) continue
      if (socket.readyState === WebSocket.OPEN) socket.send(message)
    }
  })
  const location = new LocationShare(() => controller.guest())
  computer.setFreezeAllowed(() => !location.sharing)
  const nowPlaying = new NowPlaying(() => controller.guest(), broadcast)
  /** Media is polled only while the computer is already running and someone is watching it. */
  function syncMedia(): void {
    const watching = computer.state === 'running' && sockets.size - controls.size - terminals.size > 0
    media.setActive(watching)
    nowPlaying.setActive(watching)
    const phones = computer.state === 'running' && [...phoneControls].some(socket => !backgroundControls.has(socket))
    phone.setActive(phones)
    bridge.setActive(phones)
  }
  /**
   * At each wake the computer starts without the phone's location, and gets the phone's
   * appearance once its components (which bring caboose-bridge) are up to date.
   */
  function bridgeWake(): void {
    const release = computer.acquire()
    const work = upgradeWork
    void (async () => {
      try {
        await location.computerRunning()
        if (!bridge.appearance) return
        await work
        if (computer.state !== 'running') return
        await bridge.applyAppearance().catch(error => console.error('Could not apply the phone appearance:', error instanceof Error ? error.message : error))
      } finally { release() }
    })().catch(error => console.error('Could not prepare phone bridge:', error instanceof Error ? error.message : error))
  }
  /** The terminal service is a guest component: wait for a pending update to install it. */
  async function ensureTerminalReady(): Promise<TerminalService> {
    await upgradeWork
    if (upgrade?.state === 'failed') throw new ComputerConflictError(upgrade.message ?? 'Caboose components could not be updated')
    if (!controller.terminalService || !controller.guest()) throw new AgentUnavailableError()
    return controller.terminalService()
  }
  async function ensureFilesReady(): Promise<void> {
    await upgradeWork
    if (upgrade?.state === 'failed') throw new ComputerConflictError(upgrade.message ?? 'Caboose components could not be updated')
    const warning = controller.componentsWarning?.()
    if (warning) throw new ComputerConflictError(warning)
  }
  async function ensureKeyringReady(): Promise<void> {
    await upgradeWork
    // An existing/custom store may require an interactive unlock or recovery tool.
    // Keep that route available; the persistent status carries the preparation error.
  }
  function managementStatus() {
    const desired = settings.get()
    const active = controller.activeResources()
    const tasks = agents.list()
    return {
      state: computer.state, settings: desired, limits: settings.limits, sizes: computerSizes(shared.gpuEnabled), activeResources: active,
      restartRequired: controller.hasSavedState() && (!active || active.memoryMb !== desired.memoryMb || active.vcpus !== desired.vcpus),
      clients: { display: sockets.size - controls.size - terminals.size, control: controls.size, terminal: terminals.size },
      tasks: { running: tasks.filter(task => task.status === 'running').length, paused: tasks.filter(task => task.status === 'paused').length },
      capabilities: { restart: typeof controller.restart === 'function', push: !!push },
      upgrade, keyring,
      routines: { error: routineError },
      agentTools: { error: toolsError },
      lastError: computer.lastError ?? controller.lastError?.() ?? null,
    }
  }
  /**
   * Long guest work (an agent install can take minutes) holds a lease so the computer is not
   * parked under it, without queueing every other request behind it as computer.run would.
   */
  async function leased<R>(work: () => Promise<R>): Promise<R> {
    const release = computer.acquire()
    try {
      if (computer.state === 'frozen') await computer.wake('headless')
      if (computer.state !== 'running') throw new ComputerConflictError('Computer is not running')
      return await work()
    } finally { release() }
  }
  function broadcastSettings(): void { broadcast({ type: 'computer.settings', computer: managementStatus() }) }
  function closeSockets(): void { for (const socket of sockets) socket.terminate() }
  let previousState = computer.state
  computer.subscribe(state => {
    const resumed = state === 'running' && previousState === 'frozen'
    previousState = state
    if (state === 'parking') closeSockets()
    broadcast({ type: 'computer.state', state })
    if (state !== 'running' && state !== 'frozen') { keyringGeneration++; keyring = null }
    if (state === 'running' && !resumed && controller.componentsMode && !upgrading) {
      const guest = controller.guest()
      if (guest) {
        upgrading = true
        const release = computer.acquire()
        const generation = ++keyringGeneration
        keyring = pieces.prepareKeyring ? { state: 'preparing' } : null
        upgradeWork = upgradeComponents(guest, controller.componentsMode, publishUpgrade).then(async () => {
          if (!pieces.prepareKeyring) return
          try {
            if (upgrade?.state === 'failed') throw new Error('Update guest components before preparing the keyring')
            await pieces.prepareKeyring()
            if (generation === keyringGeneration && computer.state === 'running') keyring = { state: 'ready' }
          } catch (error) {
            if (generation === keyringGeneration && computer.state === 'running') keyring = { state: 'failed', message: error instanceof Error ? error.message : 'The computer keyring is unavailable' }
          }
          if (generation === keyringGeneration && computer.state === 'running') broadcastSettings()
        }).finally(() => { upgrading = false; release() })
      }
    }
    if (state === 'running') { agents.resume(); if (!resumed) bridgeWake() }
    else if (state === 'frozen') agents.pause()
    else { agents.pause(); media.computerStopped(); nowPlaying.computerStopped(); bridge.computerStopped(); location.computerStopped() }
    syncMedia()
    syncFiles()
    desktopNotifications.setActive(state === 'running')
    broadcastSettings()
  })
  /** Phones' sockets by phone, so signing a phone out closes what it has open. */
  const phoneSockets = new Map<WebSocket, string>()

  /** A confirmed restart; `stage` runs inside it, after sockets close and before the computer stops. */
  async function confirmedRestart(stage?: () => Promise<void>): Promise<void> {
    if (upgrading) throw new ComputerConflictError('Caboose components are updating')
    if (appCatalog.busy || craftBusy) throw new ComputerConflictError('An application operation is in progress')
    await computer.restart(async () => {
      closeSockets()
      // The cold boot stops every task. Do not wait for per-task cancellation:
      // an unresponsive guest must not prevent its own restart.
      await stage?.()
    })
    agents.computerRestarted()
    broadcastSettings()
  }

  async function handle(request: IncomingMessage, response: ServerResponse, path: string, principal: Principal): Promise<unknown> {
    if (path === '/v1/agent/routines' || path.startsWith('/v1/agent/routines/')) {
      const routines = await routinesReady
      if (!routines) return json(response, 503, { error: routineError ?? 'Agent routines are unavailable' })
      if (path === '/v1/agent/routines' && request.method === 'GET') return json(response, 200, { routines: routines.list(), error: routineError })
      if (path === '/v1/agent/routines' && request.method === 'POST') return json(response, 201, { routine: await routines.create(await readJson(request)) })
      if (path === '/v1/agent/routines/history' && request.method === 'GET') return json(response, 200, { runs: routines.history() })
      const match = /^\/v1\/agent\/routines\/([0-9a-f-]{36})(?:\/(run|history))?$/.exec(path)
      if (match) {
        const [, routineId, action] = match
        if (action === 'history' && request.method === 'GET') return json(response, 200, { runs: routines.history(routineId!) })
        if (action === 'run' && request.method === 'POST') { const run = await routines.runNow(routineId!); return json(response, 202, { run: { ...run, input: {} } }) }
        if (!action && request.method === 'GET') return json(response, 200, { routine: routines.get(routineId!) })
        if (!action && request.method === 'PATCH') return json(response, 200, { routine: await routines.update(routineId!, await readJson(request)) })
        if (!action && request.method === 'DELETE') { await routines.delete(routineId!); return json(response, 200, { deleted: true }) }
      }
      return json(response, 404, NOT_FOUND)
    }
    if (path === '/v1/agent/profiles' || path.startsWith('/v1/agent/profiles/')) {
      const profiles = pieces.profiles
      if (!profiles) return json(response, 503, { error: 'Agent profiles are unavailable' })
      if (path === '/v1/agent/profiles' && request.method === 'GET') return json(response, 200, { profiles: profiles.list(true) })
      if (path === '/v1/agent/profiles' && request.method === 'POST') {
        const profile = await profiles.create(await readJson(request))
        broadcast({ type: 'agent.profiles.changed' })
        return json(response, 201, { profile })
      }
      const profilePath = /^\/v1\/agent\/profiles\/([0-9a-f-]{36})(?:\/memories(?:\/([0-9a-f-]{36}))?)?$/.exec(path)
      if (profilePath) {
        const [, id, memoryId] = profilePath
        if (path.endsWith(id!) && request.method === 'GET') return json(response, 200, { profile: profiles.get(id!) })
        let profile
        if (path.endsWith(id!) && request.method === 'PATCH') profile = await profiles.update(id!, await readJson(request))
        else if (path.endsWith('/memories') && request.method === 'POST') profile = await profiles.remember(id!, await readJson(request))
        else if (memoryId && request.method === 'PATCH') profile = await profiles.remember(id!, await readJson(request), memoryId)
        else if (memoryId && request.method === 'DELETE') profile = await profiles.forget(id!, memoryId)
        if (profile) {
          await (await routinesReady)?.profileChanged(profile.id)
          broadcast({ type: 'agent.profiles.changed' })
          return json(response, 200, { profile })
        }
      }
      return json(response, 404, { error: 'Profile route not found' })
    }
    if (request.method === 'GET' && path === '/v1/terminal/sessions') {
      return json(response, 200, { sessions: await computer.run(async () => listTerminalSessions(await ensureTerminalReady())) })
    }
    const terminalSession = /^\/v1\/terminal\/sessions\/([^/]+)$/.exec(path)
    if (request.method === 'DELETE' && terminalSession?.[1]) {
      await computer.run(async () => hangupTerminal(await ensureTerminalReady(), terminalSession[1]!))
      return json(response, 200, { hungUp: true })
    }
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
        await ensureKeyringReady()
        if (typeof input.app === 'string') await controller.launch(input.app, relative)
        else await openOnDisplay(controller.guest()!, `/home/caboose/${relative}`)
        return json(response, 200, { opened: true })
      })
    }
    const webviewBridge = /^\/v1\/webview\/([0-9a-f]{32})\/bridge$/.exec(path)
    if (webviewBridge) {
      return computer.wakeAndRun(async () => {
        await ensureFilesReady()
        if (!controller.fileService) throw new AgentUnavailableError()
        await proxyWebview(controller.fileService(), webviewBridge[1]!, request, response)
      })
    }
    if (path.startsWith('/v1/fs/')) {
      if (request.method === 'GET' && controller.parkedFilesView && computer.state === 'parked') {
        try {
          const served = await computer.parkedExclusive(async generation => {
            const view = await controller.parkedFilesView!()
            if (!view || !computer.isParkedGenerationCurrent(generation)) return false
            return serveParkedFiles(view, request, response, () => computer.isParkedGenerationCurrent(generation))
          })
          if (served) return
        } catch (error) {
          if (response.headersSent) { response.destroy(error instanceof Error ? error : undefined); return }
        }
      }
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
      const rawInput = await readJson(request)
      await shared.validateSize(rawInput)
      const input = expandSize(rawInput, shared.gpuEnabled)
      if ('defaultAgent' in input) await catalog.ensureKnown(input.defaultAgent)
      if (admit && ('memoryMb' in input || 'vcpus' in input)) await admit(id, updateSettings(settings.get(), input, settings.limits))
      const updated = await settings.update(input)
      computer.setIdleMs(updated.idleMs)
      broadcastSettings()
      return json(response, 200, managementStatus())
    }
    if (request.method === 'POST' && path === '/v1/computer/restart') {
      const body = await readJson(request)
      if (body.confirm !== true) throw new SettingsInputError('Restart closes apps and discards unsaved work; confirm must be true')
      await confirmedRestart()
      return json(response, 200, managementStatus())
    }
    if (path === '/v1/recovery' || path.startsWith('/v1/recovery/') || path === '/v1/backup' || path.startsWith('/v1/backup/')) {
      if (path.startsWith('/v1/recovery') && principal.kind === 'phone') return json(response, 403, { error: 'Only administrators manage host captures' })
      if (path.startsWith('/v1/recovery') && !pieces.storage) return recoveryRoute(undefined, request, response, path, principal, {} as never)
      if (!pieces.storage) return json(response, 404, { error: 'This computer cannot be backed up to a phone' })
      return pieces.storage.backups(request, response, path, principal, {
        restart: confirmedRestart,
        checkDisk: async replacement => {
          if (!controller.checkDiskReplacement || !controller.replaceDiskOnRestart) throw new ComputerConflictError('This computer cannot be restored')
          await controller.checkDiskReplacement(replacement).catch(error => { throw new ComputerConflictError(error instanceof Error ? error.message : String(error)) })
        },
        replaceDisk: replacement => controller.replaceDiskOnRestart!(replacement),
      })
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
    if (path.startsWith('/v1/mcp/')) {
      if (!mcp || !shared.library?.mcp) throw new AgentNotFoundError('This host has no MCP Library')
      const mcpCatalog = shared.library.mcp.catalog
      const params = new URL(request.url ?? '/', 'http://localhost').searchParams
      // Catalog entries as clients see them: an icon id in place of its source, and whether this computer has the server.
      const view = async (servers: import('./smithery.js').McpServer[]) => {
        const added = new Map((await mcp.connections()).connections.map(c => [c.server, c.id]))
        return servers.map(({ iconUrl, ...server }) => ({ ...server, iconId: mcpCatalog.iconId(iconUrl), connection: added.get(server.id) ?? null }))
      }
      const guarded = async <T>(work: () => Promise<T>) => { try { return await work() } catch (error) { if (error instanceof RangeError) throw new AgentInputError(error.message); throw error } }
      if (path === '/v1/mcp/account') {
        if (request.method === 'GET') return json(response, 200, await mcp.account())
        if (request.method === 'PUT') return json(response, 200, await mcp.connect((await readJson(request) as { apiKey?: unknown }).apiKey))
        if (request.method === 'DELETE') return json(response, 200, await mcp.disconnect())
      }
      if (request.method === 'GET' && path === '/v1/mcp/storefront') {
        let error: string | null = null
        const groups = await mcpCatalog.storefront().catch(cause => { error = `Smithery could not be reached: ${cause instanceof Error ? cause.message : String(cause)}`.slice(0, 300); return [] })
        return json(response, 200, { groups: await Promise.all(groups.map(async group => ({ ...group, servers: await view(group.servers) }))), error })
      }
      if (request.method === 'GET' && path === '/v1/mcp/discover') {
        const page = params.get('page') ?? '1'
        if (!/^\d{1,3}$/.test(page)) throw new AgentInputError('Invalid page')
        const group = params.get('group')
        const result = await guarded(() => group ? mcpCatalog.group(group, Number(page)) : mcpCatalog.search(params.get('q') ?? '', Number(page)))
        return json(response, 200, { ...result, servers: await view(result.servers) })
      }
      const serverPath = /^\/v1\/mcp\/servers\/(.+)$/.exec(path)
      if (request.method === 'GET' && serverPath?.[1]) {
        const detail = await guarded(() => mcpCatalog.detail(decodeURIComponent(serverPath[1]!)))
        const [server] = await view([detail])
        return json(response, 200, { ...server, tools: detail.tools })
      }
      const icon = /^\/v1\/mcp\/icons\/([0-9a-f]{32})$/.exec(path)
      if (request.method === 'GET' && icon?.[1]) {
        const bytes = await mcpCatalog.icon(icon[1])
        if (!bytes) throw new AgentNotFoundError('No icon')
        response.writeHead(200, { 'content-type': bytes[0] === 0xff ? 'image/jpeg' : 'image/png', 'cache-control': 'private, max-age=86400', 'x-content-type-options': 'nosniff' })
        return response.end(bytes)
      }
      if (path === '/v1/mcp/connections') {
        if (request.method === 'GET') return json(response, 200, params.get('refresh') === '1' ? await mcp.refresh() : await mcp.connections())
        if (request.method === 'POST') return json(response, 201, await guarded(async () => mcp.add((await readJson(request) as { server?: unknown }).server)))
      }
      const connection = /^\/v1\/mcp\/connections\/(cb-[0-9a-f]{12}-[0-9a-f]{16})(\/check)?$/.exec(path)
      if (connection?.[1]) {
        if (request.method === 'POST' && connection[2]) return json(response, 200, await mcp.check(connection[1]))
        if (request.method === 'PATCH' && !connection[2]) return json(response, 200, await mcp.configure(connection[1], (await readJson(request) as { values?: unknown }).values))
        if (request.method === 'DELETE' && !connection[2]) return json(response, 200, await mcp.remove(connection[1]))
      }
      throw new AgentNotFoundError('Not found')
    }
    if (request.method === 'GET' && path === '/v1/catalog/discover') {
      const params = new URL(request.url ?? '/', 'http://localhost').searchParams
      const offset = params.get('offset') ?? '0'
      if (!/^\d{1,6}$/.test(offset)) throw new AgentInputError('Invalid offset')
      return json(response, 200, await appCatalog.discover(params.get('q') ?? '', params.get('category') ?? '', Number(offset)))
    }
    if (request.method === 'GET' && path === '/v1/catalog/storefront') return json(response, 200, await appCatalog.storefront())
    if (request.method === 'GET' && path === '/v1/catalog') {
      if (computer.state === 'running' || computer.state === 'frozen') return json(response, 200, await leased(() => appCatalog.list()))
      return json(response, 200, await appCatalog.list())
    }
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
    const appAction = /^\/v1\/catalog\/([^/]+)\/(install|update)$/.exec(path)
    if (request.method === 'POST' && appAction?.[1]) return leased(async () => { if (craftBusy) throw new ComputerConflictError('A Craft job is running'); if (upgrading) throw new ComputerConflictError('Caboose components are updating'); await appCatalog.restore().catch(() => {}); await appCatalog.ready(); appCatalog.start(decodeURIComponent(appAction[1]!), appAction[2] as 'install' | 'update'); return json(response, 202, { accepted: true }) })
    const removeApp = /^\/v1\/catalog\/([^/]+)$/.exec(path)
    if (request.method === 'DELETE' && removeApp?.[1]) return leased(async () => { if (craftBusy) throw new ComputerConflictError('A Craft job is running'); if (upgrading) throw new ComputerConflictError('Caboose components are updating'); await appCatalog.restore().catch(() => {}); await appCatalog.ready(); appCatalog.start(decodeURIComponent(removeApp[1]!), 'remove'); return json(response, 202, { accepted: true }) })
    if (request.method === 'GET' && path === '/v1/apps') {
      return json(response, 200, await computer.run(() => controller.apps()))
    }
    const desktopShortcut = /^\/v1\/apps\/([^/]+)\/desktop-shortcut$/.exec(path)
    if (request.method === 'POST' && desktopShortcut?.[1]) {
      return json(response, 201, await computer.run(async () => {
        const guest = controller.guest()
        if (!guest) throw new AgentUnavailableError()
        return createDesktopShortcut(guest, decodeURIComponent(desktopShortcut[1]!))
      }))
    }
    const match = /^\/v1\/apps\/([^/]+)\/launch$/.exec(path)
    if (request.method === 'POST' && match?.[1]) {
      const { action } = parseAppLaunch(await readJson(request))
      // Phase timings contain no IDs, command arguments, tokens or guest error text.
      // Wake includes time queued behind other lifecycle operations.
      const started = performance.now()
      const initialState = computer.state
      let phase = 'wake', wakeMs: number | undefined, prepareMs: number | undefined
      let outcome = 'failed'
      try {
        await computer.wakeAndRun(async () => {
          wakeMs = Math.round(performance.now() - started)
          phase = 'prepare'
          const preparing = performance.now()
          await ensureKeyringReady()
          prepareMs = Math.round(performance.now() - preparing)
          phase = 'dispatch'
          await controller.launch(decodeURIComponent(match[1]!), undefined, action)
        })
        outcome = 'acknowledged'
      } finally {
        console.info('App launch timing', { initialState, phase, outcome, wakeMs, prepareMs,
          totalMs: Math.round(performance.now() - started) })
      }
      return json(response, 200, { launched: true })
    }
    if (request.method === 'GET' && path === '/v1/agents') return json(response, 200, await catalog.list())
    const agentAction = /^\/v1\/agents\/([^/]+)\/(install|sign-in|sign-in\/callback|sign-in\/cancel)$/.exec(path)
    if (request.method === 'POST' && agentAction?.[1]) {
      const id = decodeURIComponent(agentAction[1])
      const input = await readJson(request)
      if (agentAction[2] === 'install') {
        const agent = await leased(() => catalog.install(id))
        broadcastSettings()
        return json(response, 200, { agent })
      }
      if (agentAction[2] === 'sign-in/callback') return json(response, 200, await leased(() => catalog.signInCallback(id, input)))
      if (agentAction[2] === 'sign-in/cancel') return json(response, 200, await leased(() => catalog.cancelSignIn(id, input)))
      return json(response, 200, await computer.wakeAndRun(() => catalog.signIn(id, input), input.on === 'phone' ? 'headless' : 'interactive'))
    }
    const agentModels = /^\/v1\/agents\/([^/]+)\/models$/.exec(path)
    if (request.method === 'POST' && agentModels?.[1]) return json(response, 200, await leased(() => catalog.models(decodeURIComponent(agentModels[1]!))))
    const taskModels = /^\/v1\/agent\/tasks\/([0-9a-f-]{36})\/models$/.exec(path)
    if (taskModels?.[1] && (request.method === 'GET' || request.method === 'PUT')) {
      const input = request.method === 'PUT' ? await readJson(request) : undefined
      return json(response, 200, await computer.run(() => agents.models(taskModels[1]!, input)))
    }
    const agentEnv = /^\/v1\/agents\/([^/]+)\/env$/.exec(path)
    if (request.method === 'PUT' && agentEnv?.[1]) {
      const input = await readJson(request)
      return json(response, 200, await leased(() => catalog.setEnv(decodeURIComponent(agentEnv[1]!), input)))
    }
    if (path === '/v1/agent/tasks' && request.method === 'GET') return json(response, 200, agents.list())
    if (path === '/v1/agent/tasks' && request.method === 'POST') {
      const input = await readJson(request, TASK_BODY_LIMIT)
      const prepared = prepareProfileStart(pieces.profiles, input)
      const task = await computer.wakeAndRun(async () => { await ensureFilesReady(); return agents.start(prepared.input, { profile: prepared.profile }) }, 'headless')
      return json(response, 200, { id: task.id })
    }
    const deleteTask = /^\/v1\/agent\/tasks\/([0-9a-f-]{36})$/.exec(path)
    if (request.method === 'DELETE' && deleteTask?.[1]) {
      const input = await readJson(request)
      if (input.stop !== undefined && typeof input.stop !== 'boolean') throw new AgentInputError('stop must be a boolean')
      return json(response, 200, { deleted: await computer.run(() => agents.delete(deleteTask[1]!, input.stop === true)) })
    }
    const transcript = /^\/v1\/agent\/tasks\/([0-9a-f-]{36})\/transcript$/.exec(path)
    if (request.method === 'GET' && transcript?.[1]) {
      return json(response, 200, await computer.run(() => agents.transcript(transcript[1]!)))
    }
    const reply = /^\/v1\/agent\/tasks\/([0-9a-f-]{36})\/reply$/.exec(path)
    if (request.method === 'POST' && reply?.[1]) {
      const input = await readJson(request, TASK_BODY_LIMIT)
      return json(response, 200, { task: await computer.wakeAndRun(async () => { await ensureFilesReady(); return agents.reply(reply[1]!, input) }, 'headless') })
    }
    const sendNow = /^\/v1\/agent\/tasks\/([0-9a-f-]{36})\/send-now$/.exec(path)
    if (request.method === 'POST' && sendNow?.[1]) {
      return json(response, 200, { task: await computer.run(() => agents.sendNow(sendNow[1]!)) })
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
    if (request.method === 'GET' && path === '/v1/now-playing') {
      return json(response, 200, { nowPlaying: await nowPlaying.read(computer.state === 'running') })
    }
    const nowPlayingControl = /^\/v1\/now-playing\/([^/]+)\/control$/.exec(path)
    if (request.method === 'POST' && nowPlayingControl?.[1]) {
      const command = parseNowPlayingCommand(nowPlayingControl[1], await readJson(request))
      await computer.run(() => nowPlaying.send(command))
      return json(response, 200, { sent: true })
    }
    const bridgeAnswer = /^\/v1\/bridge\/requests\/([^/]+)$/.exec(path)
    if (request.method === 'POST' && bridgeAnswer?.[1]) {
      const input = await readJson(request)
      await computer.run(() => bridge.answer(bridgeAnswer[1]!, input, principal.phoneId))
      return noContent(response)
    }
    if (request.method === 'PUT' && path === '/v1/bridge/appearance') {
      bridge.appearance = parseAppearance(await readJson(request))
      // While components update, the wake's own apply runs once caboose-bridge is installed.
      if (computer.state === 'running' && !upgrading) await computer.run(() => bridge.applyAppearance())
      return noContent(response)
    }
    if (request.method === 'PUT' && path === '/v1/bridge/location') {
      const shared = parseLocation(await readJson(request))
      await computer.run(() => location.set(shared))
      return noContent(response)
    }
    if (request.method === 'DELETE' && path === '/v1/bridge/location') {
      // A parked computer's file is removed when it next runs.
      if (computer.state === 'running') {
        await computer.run(() => location.clear()).catch(error => { if (!(error instanceof ComputerConflictError)) throw error })
      }
      location.computerStopped()
      return noContent(response)
    }
    if (request.method === 'GET' && path === '/v1/screen/elements') return json(response, 200, await computer.wakeAndRun(() => screenElements(controller.guest())))
    const screen = { '/v1/screen/act': screenAct, '/v1/screen/type': screenType, '/v1/screen/keys': screenKeys }[path]
    if (request.method === 'POST' && screen) {
      const input = await readJson(request)
      return json(response, 200, await computer.wakeAndRun(() => screen(controller.guest(), input)))
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
      return json(response, 200, await computer.wakeAndRun(async () => { await ensureKeyringReady(); return openUrl(controller.guest(), input) }))
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

  /** Accepts a terminal upgrade once the computer runs, waking it first when asked to. */
  function connectTerminal(request: IncomingMessage, socket: Duplex, head: Buffer, url: URL, principal: Principal): void {
    const refuse = (status: string) => { if (!socket.destroyed) socket.end(`HTTP/1.1 ${status}\r\nConnection: close\r\n\r\n`) }
    let query: TerminalQuery
    try { query = parseTerminalQuery(url.searchParams) } catch { return refuse('400 Bad Request') }
    const client = principal.phoneId ?? (principal.kind === 'admin' ? principal.userId : 'owner')
    const open = [...terminals.values()].filter(owner => owner === client).length + (pendingTerminals.get(client) ?? 0)
    if (open >= MAX_TERMINALS) return refuse('429 Too Many Requests')
    if (!computer.acceptsConnections && !query.wake) return refuse('409 Conflict')
    const release = computer.acquire()
    socket.once('close', release)
    pendingTerminals.set(client, (pendingTerminals.get(client) ?? 0) + 1)
    const ready = computer.state === 'frozen' ? computer.wake('headless') : computer.acceptsConnections ? Promise.resolve() : computer.wakeAndRun(async () => {})
    ready.then(ensureTerminalReady).then(service => {
      if (socket.destroyed) return
      if (!computer.acceptsConnections) return refuse('409 Conflict')
      wss.handleUpgrade(request, socket, head, ws => {
        sockets.add(ws)
        terminals.set(ws, client)
        if (principal.phoneId) phoneSockets.set(ws, principal.phoneId)
        ws.on('error', () => ws.terminate())
        ws.once('close', () => { sockets.delete(ws); terminals.delete(ws); phoneSockets.delete(ws); release() })
        relayTerminal(ws, guestTerminalUrl(service, query), service.token)
      })
    }, error => {
      refuse(error instanceof ComputerConflictError || error instanceof AgentUnavailableError ? '409 Conflict' : '502 Bad Gateway')
    }).finally(() => {
      const left = (pendingTerminals.get(client) ?? 1) - 1
      if (left > 0) pendingTerminals.set(client, left); else pendingTerminals.delete(client)
    }).catch(() => socket.destroy())
  }

  function connect(request: IncomingMessage, socket: Duplex, head: Buffer, url: URL, path: string, principal: Principal): void {
    if (path === '/v1/terminal') return connectTerminal(request, socket, head, url, principal)
    if (!computer.acceptsConnections) { socket.end('HTTP/1.1 409 Conflict\r\nConnection: close\r\n\r\n'); return }
    const offered = request.headers['sec-websocket-protocol']?.split(',').map(value => value.trim()) ?? []
    if (path === '/v1/display' && !offered.includes('binary')) { socket.end('HTTP/1.1 400 Bad Request\r\nConnection: close\r\n\r\n'); return }
    const background = path === '/v1/control' && url.searchParams.get('foreground') === '0'
    const release = computer.acquire()
    socket.once('close', release)
    const ready = path === '/v1/display' && url.searchParams.get('seat') !== 'agent' ? computer.wake() : computer.state === 'frozen' ? computer.wake('headless') : Promise.resolve()
    void ready.then(() => {
      if (socket.destroyed) return
      try {
      wss.handleUpgrade(request, socket, head, client => {
        sockets.add(client)
        if (principal.phoneId) phoneSockets.set(client, principal.phoneId)
        if (path === '/v1/control') {
          controls.add(client)
          if (url.searchParams.get('foreground') === '0') backgroundControls.add(client)
          if (url.searchParams.get('foreground') === '1') foregroundClients.add(client)
          if (url.searchParams.get('phone') === '1') phoneControls.add(client)
          if (background) release()
        }
        syncMedia()
        syncFiles()
        client.on('error', () => client.terminate())
        client.once('close', () => { sockets.delete(client); phoneSockets.delete(client); controls.delete(client); foregroundClients.delete(client); backgroundControls.delete(client); phoneControls.delete(client); release(); syncMedia(); syncFiles() })
        if (path === '/v1/control') {
          client.send(JSON.stringify({ type: 'computer.state', state: computer.state }))
          client.send(JSON.stringify({ type: 'computer.settings', computer: managementStatus() }))
          const playing = media.watched()
          if (playing) client.send(JSON.stringify({ type: 'media.playing', media: playing }))
          const track = nowPlaying.watched()
          if (track) client.send(JSON.stringify({ type: 'now-playing.changed', nowPlaying: track }))
          return
        }
        if (url.searchParams.get('seat') === 'agent') {
          // The agent seat starts on demand; hold the client until it is up.
          client.pause()
          ensureFilesReady().then(() => controller.ensureAgentSeat()).then(
            () => { if (client.readyState === WebSocket.OPEN) relay(client, controller.agentDisplayUrl) },
            () => client.close(1011, 'agent seat unavailable'))
          return
        }
        relay(client, controller.displayUrl)
      })
      } catch { release(); socket.destroy() }
    }, () => { release(); socket.destroy() })
  }

  function disconnectPhone(phoneId: string): void {
    for (const [socket, phone] of phoneSockets) if (phone === phoneId) socket.terminate()
  }

  async function shutdown(): Promise<void> {
    await tiering?.close()
    pieces.storage?.close()
    clearInterval(autoUpdates)
    await (await routinesReady)?.close()
    agents.pause()
    await agents.drainToolWork()
    await (await toolJournalReady)?.drain()
    await upgradeWork
    await computer.park(closeSockets)
  }

  /**
   * Deletes the computer once queued work is done: its sockets close, its tasks end and its
   * disk goes. A components upgrade the host started on its own is waited for, not refused.
   */
  async function destroy(): Promise<void> {
    clearInterval(autoUpdates)
    await (await routinesReady)?.close()
    agents.pause()
    await agents.drainToolWork()
    await (await toolJournalReady)?.drain()
    await upgradeWork?.catch(() => {})
    await computer.retire(async () => {
      closeSockets()
      agents.computerRestarted()
      if (!controller.destroy) throw new ComputerConflictError('This runtime cannot delete a computer')
      await controller.destroy()
      await pieces.storage?.destroy()
    })
  }

  return { id, controller: pieces.controller, computer, settings, push, activities, managementStatus, handle, connect, disconnectPhone, shutdown, destroy,
    /** What someone started on the computer that deleting it would cut short, if anything. */
    operation: () => appCatalog.busy ? 'An app is being installed, updated or removed on this computer' : craftBusy > 0 ? 'A Craft job is running on this computer' : null,
  }
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
  /** Bytes a computer's disk uses on the host, or null when the runtime cannot tell. */
  diskBytes?(record: ComputerRecord): Promise<number | null>
}

export function createCabooseServer(options: ComputerPieces & {
  token: string; webRoot?: string
  /** The ACP agent registry; defaults to the public registry, cached in memory only. */
  registry?: AgentRegistry
  /** Flathub, Craft releases and the shared runtime depot. */
  library?: Library
  /** How long a task's runner keeps its agent after a turn, waiting for a reply. */
  agentIdleMs?: number
  freezeParkMs?: number
  /** How this host was started, for `GET /v1/host`. */
  host?: HostInfo
  /** The machine's memory, CPUs and disk, for `GET /v1/health`. */
  machine?: () => Promise<MachineResources>
  /** Image filesystem for read-only capacity sampling. */
  capacityRoot?: string
  usageHistoryFile?: string
  /** Shared storage's totals, for `GET /v1/health`; null when it is off. */
  sharedStorage?: () => SharedStorageStatus | null
  /** How phones find and reach this host, for `/v1/host/reach`. */
  reach?: ReachService
  fleet?: Fleet
  /** Accounts and tenants. Without it the owner token and phones are the only principals. */
  identity?: Identity
}) {
  const capacitySampler = new CapacitySampler(options.capacityRoot, options.host?.runtime)
  const usage = new UsageHistory(options.usageHistoryFile)
  const identity = options.identity
  const authHandler = identity ? toNodeHandler(request => identity.handleAuthentication(request)) : undefined
  const throttle = new SignInThrottle()
  const shared = {
    registry: options.registry ?? new AgentRegistry(),
    gpuEnabled: options.host?.runtime === 'container' && options.host.gpu !== null && options.host.gpu !== 'none',
    validateSize: async (input: Record<string, unknown>) => {
      if (!('size' in input) || !options.machine) return
      const size = computerSizes(options.host?.runtime === 'container' && options.host.gpu !== null && options.host.gpu !== 'none').find(entry => entry.id === input.size)
      if (!size) return
      const machine = await options.machine()
      if (size.memoryMb > machine.memoryMb || size.vcpus > machine.cpus) throw new ComputerConflictError('Computer size exceeds this host’s total memory or CPUs')
    },
    ...(options.library ? { library: options.library } : {}),
    ...(options.agentIdleMs !== undefined ? { agentIdleMs: options.agentIdleMs } : {}),
    ...(options.freezeParkMs !== undefined ? { freezeParkMs: options.freezeParkMs } : {}),
    ...(identity ? { admit: (id: string, next?: Pick<ComputerSettings, 'memoryMb' | 'vcpus'>) => admit(id, next, !next) } : {}),
  }
  const owner = createComputerRuntime(OWNER_COMPUTER, options, shared)
  const runtimes = new Map<string, ComputerRuntime>([[OWNER_COMPUTER, owner]])
  for (const { record, pieces } of options.fleet?.existing ?? []) runtimes.set(record.id, createComputerRuntime(record.id, pieces, shared))
  const records = (): ComputerRecord[] => options.fleet?.computers.list() ?? [{ id: OWNER_COMPUTER, slot: 0, createdAt: null, tenantId: null, person: null }]
  const recordOf = (id: string) => records().find(c => c.id === id)
  const describe = (runtime: ComputerRuntime) => {
    const record = recordOf(runtime.id)
    return { id: runtime.id, createdAt: record?.createdAt ?? null, tenantId: record?.tenantId ?? null, personId: record?.personId ?? null, person: record?.person ?? null, ...runtime.managementStatus() }
  }
  const tenancy: TenancyContext | undefined = identity && {
    identity,
    computers: () => records().flatMap(record => {
      const runtime = runtimes.get(record.id)
      return runtime && !deleting.has(record.id) ? [{ record, settings: runtime.settings.get() }] : []
    }),
    diskBytes: async id => {
      const record = recordOf(id)
      return record && options.fleet?.diskBytes ? options.fleet.diskBytes(record) : null
    },
    adoptUnassigned: async tenantId => { await options.fleet?.computers.adoptUnassigned(tenantId) },
    synchronize: work => options.fleet ? options.fleet.computers.synchronize(work) : work(),
  }

  /**
   * A tenant's computers may not be given more memory or vCPUs between them than its quotas
   * allow, nor (when one wakes) use more disk. `next` is a computer's proposed size, or a
   * new computer's when `id` is not yet a computer; `waking` also checks the disk.
   */
  async function admit(id: string, next: Pick<ComputerSettings, 'memoryMb' | 'vcpus'> | undefined, waking: boolean, tenantId = recordOf(id)?.tenantId ?? null): Promise<void> {
    if (!tenancy || !tenantId) return
    const tenant = await identity!.tenant(tenantId).catch(() => null)
    if (!tenant) return
    const { quotas } = tenant
    const usage = await tenantUsage(tenancy, tenantId)
    const current = tenancy.computers().find(computer => computer.record.id === id && computer.record.tenantId === tenantId)?.settings
    const memoryMb = usage.memoryMb - (current?.memoryMb ?? 0) + (next?.memoryMb ?? current?.memoryMb ?? 0)
    const vcpus = usage.vcpus - (current?.vcpus ?? 0) + (next?.vcpus ?? current?.vcpus ?? 0)
    if (quotas.memoryMb !== null && memoryMb > quotas.memoryMb) {
      throw new ComputerConflictError(`${tenant.name}'s computers would be given ${memoryMb} MiB of memory; its quota is ${quotas.memoryMb} MiB`)
    }
    if (quotas.vcpus !== null && vcpus > quotas.vcpus) {
      throw new ComputerConflictError(`${tenant.name}'s computers would be given ${vcpus} vCPUs; its quota is ${quotas.vcpus}`)
    }
    if (waking && quotas.diskGb !== null && usage.diskBytes !== null && usage.diskBytes > quotas.diskGb * 1024 ** 3) {
      throw new ComputerConflictError(`${tenant.name}'s computers use ${(usage.diskBytes / 1024 ** 3).toFixed(1)} GiB of disk; its quota is ${quotas.diskGb} GiB`)
    }
  }
  const deleting = new Set<string>()
  let usageCursor = 0
  let usageStopped = false, usageWork: Promise<void> | undefined
  // One sequential collector, no overlap; slow fleets explicitly lose interval coverage.
  function collectUsage() {
    if (usageStopped || usageWork) return
    usageWork = (async () => {
      const deadline = Date.now() + 45_000
      const all = [...runtimes.values()]
      const ordered = [...all.slice(usageCursor), ...all.slice(0, usageCursor)]
      for (const runtime of ordered) {
        if (usageStopped) break
        if (deleting.has(runtime.id)) continue
        const inBudget = Date.now() < deadline
        const sample = inBudget ? await runtime.controller.usageCounters?.().catch(() => null) ?? null : null
        if (inBudget) usageCursor = (all.indexOf(runtime) + 1) % Math.max(1, all.length)
        if (runtimes.get(runtime.id) === runtime && !deleting.has(runtime.id)) await usage.record(runtime.id, sample, Date.now(), !runtime.controller.usageCounters ? 'This runtime does not expose per-computer host resource counters' : !inBudget ? 'Collector fleet deadline reached' : 'Docker counters unavailable, stopped, or stale')
      }
      await usage.save([...runtimes.keys()].filter(id => !deleting.has(id)))
    })().catch(() => console.error('Usage history could not be saved')).finally(() => { usageWork = undefined })
  }
  const usageTimer = options.usageHistoryFile ? setInterval(collectUsage, 60_000) : undefined
  usageTimer?.unref()

  const pairing = new PairingCodes()

  async function principalOf(request: IncomingMessage): Promise<Principal | undefined> {
    if (authenticate(request.headers.authorization, options.token)) return { kind: 'owner' }
    const header = request.headers.authorization
    if (header?.startsWith('Bearer ') && options.fleet) {
      const phone = options.fleet.phones.resolve(header.slice(7))
      return phone && runtimes.has(phone.computerId) ? { kind: 'phone', ...phone } : undefined
    }
    return identity && !header ? identity.principal(webHeaders(request)) : undefined
  }

  /** Whether a principal may manage a computer: the operator any, an administrator their tenants'. */
  function manages(principal: Principal, id: string): boolean {
    if (principal.kind === 'phone') return false
    return administers(principal, recordOf(id)?.tenantId ?? null)
  }

  /**
   * The computer a path names (`/v1/computers/<id>/…`, for whoever manages it) or the
   * principal's own, with the path it serves. The routes without an id serve the owner's
   * computer to the owner token and the operator, and a phone's computer to that phone.
   */
  function target(path: string, principal: Principal): { runtime: ComputerRuntime; path: string } | 'forbidden' | undefined {
    const scoped = /^\/v1\/computers\/([^/]+)(\/.+)$/.exec(path)
    if (scoped) {
      if (principal.kind === 'phone') return 'forbidden'
      const runtime = runtimes.get(decodeURIComponent(scoped[1]!))
      return runtime && !deleting.has(runtime.id) && manages(principal, runtime.id) ? { runtime, path: `/v1${scoped[2]}` } : undefined
    }
    if (principal.kind === 'admin' && !principal.operator) return 'forbidden'
    const runtime = runtimes.get(principal.kind === 'phone' ? principal.computerId : OWNER_COMPUTER)
    return runtime ? { runtime, path } : undefined
  }

  async function createComputer(input: Record<string, unknown>, principal: Principal): Promise<ComputerRuntime> {
    const fleet = options.fleet
    if (!fleet) throw new ComputerConflictError('This host serves one computer')
    const { tenantId: requestedTenant, person: requestedPerson, personId: requestedPersonId, ...rawSettings } = input
    await shared.validateSize(rawSettings)
    const settingsInput = expandSize(rawSettings, shared.gpuEnabled)
    if (!('name' in settingsInput)) throw new SettingsInputError('name is required')
    if ('defaultAgent' in settingsInput) throw new SettingsInputError('Unknown setting: defaultAgent')
    const initial = updateSettings({ name: 'Computer', defaultAgent: null, ...fleet.defaults }, settingsInput, settingsLimits())
    let person = personName(requestedPerson)
    let personId: string | null = null
    let tenantId: string | null = null
    if (identity) {
      if (!await identity.claimed()) throw new ComputerConflictError('Complete host setup first')
      if (typeof requestedTenant !== 'string') throw new SettingsInputError('tenantId is required')
      if (principal.kind === 'phone' || !administers(principal, requestedTenant)) throw new SettingsInputError('tenant not found')
      await identity.tenant(requestedTenant)
      tenantId = requestedTenant
      if (requestedPersonId !== undefined) {
        if (person !== null) throw new SettingsInputError('Send personId, not both personId and person')
        if (typeof requestedPersonId !== 'string') throw new SettingsInputError('personId is required')
        const selected = await identity.person(requestedPersonId)
        if (selected.tenantId !== tenantId) throw new SettingsInputError('Person must belong to the selected tenant')
        personId = selected.id
        person = selected.name
      } else if (!person) throw new SettingsInputError('personId is required; choose a person in this tenant')
      await admit('', initial, false, tenantId)
    } else if (requestedTenant !== undefined) throw new SettingsInputError('This host has no tenants')
    const record = await fleet.computers.create({ tenantId, person, personId })
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
    const operation = runtime.operation()
    if (operation) throw new ComputerConflictError(`${operation}; delete it when that finishes`)
    deleting.add(runtime.id)
    try {
      await runtime.destroy()
      pairing.revokeComputer(runtime.id)
      await fleet.phones.revokeComputer(runtime.id)
      await fleet.computers.remove(runtime.id)
      await options.library?.depot?.forget(runtime.id)
      await rm(fleet.computers.dataDir(runtime.id), { recursive: true, force: true })
      runtimes.delete(runtime.id)
      await usage.save([...runtimes.keys()]).catch(() => console.error('Deleted usage history could not be persisted'))
    } finally { deleting.delete(runtime.id) }
  }

  const server = createServer((request, response) => {
    void (async () => {
      const path = new URL(request.url ?? '/', 'http://localhost').pathname
      if (path !== '/v1' && !path.startsWith('/v1/')) {
        // Until the host is claimed, its setup page requires the one-time setup code.
        if (path === '/setup' && identity) {
          if (await identity.claimed()) { response.writeHead(302, { location: '/' }); return response.end() }
          const code = new URL(request.url ?? '/', 'http://localhost').searchParams.get('code')
          if (!await identity.setupCodeMatches(code)) return json(response, 403, { error: 'Open the setup link the host printed' })
        }
        if (options.webRoot) return serveWeb(request, response, options.webRoot, path)
        return json(response, 404, { error: 'not found' })
      }
      if (identity && isSignInAttempt(request.method, path) && !throttle.allow(request)) return json(response, 429, { error: 'Too many sign-in attempts from here; try again in a few minutes' })
      if (authHandler && path.startsWith('/v1/auth/')) return authHandler(request, response)
      if (request.method === 'POST' && path === '/v1/pair') {
        // The one route without a token: a pairing code is the credential.
        const input = await readJson(request)
        const deviceName = phoneName(input.deviceName)
        const fleet = options.fleet
        if (!fleet) throw new ComputerConflictError('This host has no phone sign-ins')
        const id = pairing.redeem(input.code)
        const runtime = id ? runtimes.get(id) : undefined
        if (!runtime || deleting.has(runtime.id)) return json(response, 404, { error: 'pairing code not found or expired' })
        const { token } = await fleet.phones.mint(runtime.id, deviceName)
        return json(response, 201, { token, computer: { id: runtime.id, name: runtime.settings.get().name } })
      }
      const principal = await principalOf(request)
      const capacityTenant = /^\/v1\/tenants\/([0-9a-f-]{36})\/capacity$/.exec(path)
      if (request.method === 'GET' && (path === '/v1/host/capacity' || capacityTenant)) {
        const result = await capacityFor({
          sampler: capacitySampler,
          usage: id => usage.get(id),
          computers: () => [...runtimes.values()].filter(r => !deleting.has(r.id)).map(describe),
          quotas: async id => { if (!identity) throw new AgentNotFoundError('tenant not found'); return (await identity.tenant(id)).quotas },
          queued: () => { const stats = options.controller.stats() as { desk?: { queued?: number } }; return stats.desk?.queued ?? null },
        }, principal, capacityTenant?.[1])
        response.setHeader('cache-control', 'no-store')
        return json(response, result.status, result.body)
      }
      const usageRoute = /^\/v1\/computers\/([^/]+)\/usage(\/storage)?$/.exec(path)
      if (usageRoute) {
        if (!principal) return json(response, 401, { error: 'unauthorized' })
        if (principal.kind === 'phone') return json(response, 403, { error: 'forbidden' })
        const runtime = runtimes.get(usageRoute[1]!)
        if (!runtime || deleting.has(runtime.id) || !manages(principal, runtime.id)) return json(response, 404, { error: 'computer not found' })
        response.setHeader('cache-control', 'no-store')
        if (!usageRoute[2] && request.method === 'GET') return json(response, 200, usage.get(runtime.id))
        if (usageRoute[2] && request.method === 'POST') {
          const result = runtime.controller.usageStorage
            ? await runtime.controller.usageStorage().catch(() => { throw new ComputerConflictError('Another storage measurement is in progress') })
            : { sampledAt: Date.now(), vm: await capacitySampler.storage([runtime.id]) }
          const current = await principalOf(request)
          if (!current || current.kind === 'phone' || runtimes.get(runtime.id) !== runtime || deleting.has(runtime.id) || !manages(current, runtime.id)) return json(response, 404, { error: 'computer not found' })
          return json(response, 200, result)
        }
        return json(response, 405, { error: 'method not allowed' })
      }
      if (tenancy && await tenancyRoute(tenancy, request, response, path, principal) !== NOT_FOUND) return
      if (!principal) return json(response, 401, { error: 'unauthorized' })
      const fleetRoute = path === '/v1/computers' || /^\/v1\/computers\/[^/]+(?:\/pairing|\/phones(?:\/[^/]+)?)?$/.test(path)
      if (principal.kind === 'phone' && (fleetRoute || path === '/v1/health' || path === '/v1/host' || path.startsWith('/v1/host/'))) return json(response, 403, { error: 'forbidden' })
      if ((path === '/v1/health' || path === '/v1/host' || path.startsWith('/v1/host/')) && !administers(principal, null)) return json(response, 403, { error: 'Only the operator sees the host' })
      if (request.method === 'GET' && path === '/v1/health') {
        return json(response, 200, { ...(options.controller.stats() as object), ...(options.machine ? { machine: await options.machine() } : {}), ...(options.sharedStorage ? { sharedStorage: options.sharedStorage() } : {}) })
      }
      if (request.method === 'GET' && path === '/v1/host' && options.host) return json(response, 200, options.host)
      if (path === '/v1/host/reach' && request.method === 'GET' && options.reach) return json(response, 200, await options.reach.status())
      if (path === '/v1/host/reach/tailscale' && request.method === 'PUT' && options.reach) {
        const input = await readJson(request)
        if (typeof input.enabled !== 'boolean' || Object.keys(input).some(key => key !== 'enabled')) throw new SettingsInputError('Send { "enabled": true } or { "enabled": false }')
        return json(response, 200, await options.reach.setTailscale(input.enabled))
      }
      if (path === '/v1/computers' && request.method === 'GET') {
        return json(response, 200, {
          computers: [...runtimes.values()].filter(r => !deleting.has(r.id) && manages(principal, r.id)).map(describe),
          canCreate: !!options.fleet && (!identity || await identity.claimed()), limits: { computers: options.fleet ? MAX_SLOTS : 1, running: options.fleet?.maxRunning ?? null },
        })
      }
      if (path === '/v1/computers' && request.method === 'POST') return json(response, 201, describe(await createComputer(await readJson(request), principal)))
      const computerPath = /^\/v1\/computers\/([^/]+)(?:\/pairing|\/phones(?:\/([^/]+))?)?$/.exec(path)
      if (computerPath?.[1]) {
        const runtime = runtimes.get(decodeURIComponent(computerPath[1]))
        if (!runtime || deleting.has(runtime.id) || !manages(principal, runtime.id)) return json(response, 404, { error: 'computer not found' })
        const phones = path.slice(`/v1/computers/${computerPath[1]}`.length)
        if (!phones && request.method === 'GET') return json(response, 200, describe(runtime))
        if (!phones && request.method === 'PATCH') {
          // A computer's person, and (for the operator) its tenant.
          const input = await readJson(request)
          for (const key of Object.keys(input)) if (key !== 'person' && key !== 'tenantId' && key !== 'personId') throw new SettingsInputError(`Unknown field: ${key}`)
          if (!options.fleet) throw new ComputerConflictError('This host serves one computer')
          if (identity && !await identity.claimed()) throw new ComputerConflictError('Complete host setup first')
          if ('tenantId' in input) {
            if (!identity || (input.tenantId !== recordOf(runtime.id)?.tenantId && !administers(principal, null))) throw new SettingsInputError('Only the operator moves computers between tenants')
            if (typeof input.tenantId !== 'string') throw new SettingsInputError('tenantId must be a tenant id')
            await identity.tenant(input.tenantId)
            await admit(runtime.id, runtime.settings.get(), false, input.tenantId)
          }
          if (identity) {
            const tenantId = typeof input.tenantId === 'string' ? input.tenantId : recordOf(runtime.id)?.tenantId
            if (!tenantId) throw new SettingsInputError('Choose a tenant and person')
            if ('person' in input) throw new SettingsInputError('Choose a person by personId; rename people in People')
            if ('personId' in input && typeof input.personId !== 'string') throw new SettingsInputError('personId must identify a person')
            const personId = input.personId ?? recordOf(runtime.id)?.personId
            if (typeof personId !== 'string') throw new SettingsInputError('personId is required')
            const selected = await identity.person(personId)
            if (selected.tenantId !== tenantId) throw new SettingsInputError('Person must belong to the selected tenant')
            input.tenantId = tenantId
            input.personId = selected.id
            input.person = selected.name
          }
          await options.fleet.computers.assign(runtime.id, input as Partial<ComputerAssignment>)
          await accountSockets.revalidate()
          return json(response, 200, describe(runtime))
        }
        if (!phones && request.method === 'DELETE') {
          if ((await readJson(request)).confirm !== true) throw new SettingsInputError('Deleting a computer deletes its disk and everything on it; confirm must be true')
          await deleteComputer(runtime)
          return json(response, 200, { deleted: true })
        }
        const fleet = options.fleet
        if (phones === '/phones' && request.method === 'GET') return json(response, 200, { phones: fleet?.phones.list(runtime.id) ?? [] })
        if (phones === '/pairing' && request.method === 'POST') {
          if (!fleet) throw new ComputerConflictError('This host has no phone sign-ins')
          return json(response, 201, pairing.issue(runtime.id))
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
      // Handlers that read the request's own URL (the files relay, parked Files) see the
      // computer's path, as a phone's request would carry it.
      if (routed.path !== path) request.url = routed.path + new URL(request.url ?? '/', 'http://localhost').search
      if (await routed.runtime.handle(request, response, routed.path, principal) === NOT_FOUND) return json(response, 404, { error: 'not found' })
    })().catch(error => {
      if (error instanceof AgentInputError || error instanceof SettingsInputError || error instanceof MediaInputError || error instanceof BridgeInputError || error instanceof NowPlayingInputError || error instanceof IdentityInputError) return json(response, 400, { error: error.message })
      if (error instanceof AgentNotFoundError || error instanceof ScreenElementGoneError || error instanceof TerminalGoneError || error instanceof IdentityNotFoundError) return json(response, 404, { error: error.message })
      if (error instanceof AgentUnavailableError || error instanceof DisplayNotReadyError || error instanceof AgentConflictError || error instanceof ComputerConflictError || error instanceof ComputerCapacityError || error instanceof IdentityConflictError || error instanceof ReachUnavailableError) return json(response, 409, { error: error.message })
      if (error instanceof PairingRateLimitError || error instanceof BridgeRateLimitError) return json(response, 429, { error: error.message })
      if (error instanceof AgentOperationError || error instanceof TerminalServiceError) return json(response, 502, { error: error.message })
      console.error('Caboose request failed:', error)
      if (!response.headersSent) json(response, 500, { error: 'computer operation failed' })
      else response.destroy()
    })
  })

  const accountSockets = new AccountSocketFence()
  const unsubscribeAuthorization = identity?.onAuthorizationChange(() => accountSockets.revalidate())
  server.once('listening', () => { if (options.usageHistoryFile) collectUsage() })
  server.once('close', () => { usageStopped = true; clearInterval(usageTimer); unsubscribeAuthorization?.(); accountSockets.dispose() })

  server.on('upgrade', (request, socket, head) => void (async () => {
    const url = new URL(request.url ?? '/', 'http://localhost')
    const principal = await principalOf(request).catch(() => undefined)
    if (!principal) { socket.end('HTTP/1.1 401 Unauthorized\r\nConnection: close\r\n\r\n'); return }
    const routed = target(url.pathname, principal)
    if (routed === 'forbidden') { socket.end('HTTP/1.1 403 Forbidden\r\nConnection: close\r\n\r\n'); return }
    if (!routed || (routed.path !== '/v1/display' && routed.path !== '/v1/control' && routed.path !== '/v1/terminal')) { socket.end('HTTP/1.1 404 Not Found\r\nConnection: close\r\n\r\n'); return }
    if (principal.kind === 'admin') {
      const remove = accountSockets.add(async () => {
        const current = await identity?.principal(webHeaders(request), { disableRefresh: true })
        return current?.kind === 'admin' && current.userId === principal.userId && manages(current, routed.runtime.id)
      }, () => socket.destroy())
      socket.once('close', remove)
      // Fence a revocation racing the initial upgrade authorization.
      await accountSockets.revalidate()
      if (socket.destroyed) return
    }
    routed.runtime.connect(request, socket, head, url, routed.path, principal)
  })())

  async function shutdown(): Promise<void> {
    usageStopped = true; clearInterval(usageTimer); await usageWork
    unsubscribeAuthorization?.()
    accountSockets.dispose()
    await Promise.all([...runtimes.values()].map(runtime => runtime.shutdown().catch(error => console.error(`Computer ${runtime.id} did not park:`, error))))
    await new Promise<void>((resolve, reject) => server.close(error => error ? reject(error) : resolve()))
  }
  return { server, computer: owner.computer, shutdown }
}
