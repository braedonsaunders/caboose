// The agent seat as the tools reach it: three long-lived helpers (helpers/a11y.py for the
// accessibility tree, helpers/seat.py for windows, input and pictures through the seat's
// control socket, helpers/direct.py for direct tools), each started with the seat's launch
// environment once the seat is up, and started again when that environment changes.
import { spawn } from 'node:child_process'
import { fileURLToPath } from 'node:url'
import { Worker } from './worker.mjs'
import { controlAlive, ensureAgentSeat } from './seat-session.mjs'

const helper = name => fileURLToPath(new URL(`../helpers/${name}`, import.meta.url))
export const DISPLAY = process.env.CABOOSE_AGENT_DISPLAY ?? ':101'
export const env = { ...process.env, DISPLAY }
const LAUNCHER = helper('launcher.py')

const a11yWorker = new Worker(helper('a11y.py'), [`--display=${DISPLAY}`], 30_000)
const seatWorker = new Worker(helper('seat.py'))
const directWorker = new Worker(helper('direct.py'), [], 60_000)
let seatEnvironment

// When the last input went in, on the compositor's clock (CLOCK_MONOTONIC), and whether it was
// whether text went in since the last read: the next settled observation waits for the seat to
// react to it (to go quiet, after text). `typed` left out keeps what it was.
export const input = { at: undefined, typed: false }
export const markInput = typed => { input.at = Number(process.hrtime.bigint() / 1000n); if (typed !== undefined) input.typed = typed }
export const since = () => input.at === undefined ? [] : [String(input.at)]

// These tools are the seat's assistive technology, and say so on its accessibility bus as a
// screen reader does: Chromium, Electron and other toolkits that build their full tree only
// for one then expose it to applications started afterwards.
function announceAssistiveTechnology(seatEnv) {
  const child = spawn('gdbus', ['call', '--session', '--dest', 'org.a11y.Bus', '--object-path', '/org/a11y/bus', '--method',
    'org.freedesktop.DBus.Properties.Set', 'org.a11y.Status', 'ScreenReaderEnabled', '<true>'], { env: { ...env, ...seatEnv }, stdio: 'ignore' })
  child.on('error', () => {})
  return new Promise(resolve => { child.on('exit', resolve); child.on('error', resolve) })
}

async function request(worker, message) {
  const ready = await ensureAgentSeat()
  if (ready !== seatEnvironment) {
    close()
    seatEnvironment = ready
    await announceAssistiveTechnology(ready)
  }
  Object.assign(env, ready, { DISPLAY })
  try {
    const answer = await worker.request(message, env)
    if (answer.error) throw new Error(answer.error)
    return answer
  } catch (error) {
    if (!await controlAlive(env)) ensureAgentSeat.invalidate()
    throw error
  }
}

/** The accessibility helper's answer to one operation (elements, find, text, act). */
export async function a11y(op, options = {}) {
  if (op === 'act') markInput(options.action === 'set-text')
  return request(a11yWorker, { op, ...options })
}
/** One seat.py command: windows, click, key, type, scroll, drag, focus, settle, screenshot, annotate. */
export const seat = (...args) => request(seatWorker, { args })
/** One direct.py request: list, call, where. */
export const direct = message => request(directWorker, message)

/** The window that has the keyboard, or the one an open menu or tooltip of it belongs to. */
export function owning(listing, id = listing.focused) {
  let window = listing.windows.find(w => w.id === id)
  for (let hops = 0; window?.kind === 'popup' && window.parent != null && hops < 8; hops++)
    window = listing.windows.find(w => w.id === window.parent) ?? window
  return window
}
export async function focusedWindow() {
  const window = owning(await seat('windows'))
  return window ? { pid: window.pid, app_id: window.app_id, desktop_id: window.desktop_id, title: window.title } : null
}
export async function focusedPid() {
  const listing = await seat('windows')
  return listing.windows.find(w => w.id === listing.focused)?.pid
}

// What a launched app needs to build its accessibility tree: GTK's bridge must not be
// switched off (NO_AT_BRIDGE, GTK_A11Y=none), Chromium and Electron read
// ACCESSIBILITY_ENABLED, Gecko GNOME_ACCESSIBILITY, Qt QT_LINUX_ACCESSIBILITY_ALWAYS_ON.
// The seat is a Wayland session; saying so makes Chromium and Electron run as Wayland
// clients, whose fields take the seat's text and whose windows place their controls exactly.
const launchEnv = { ...env, ACCESSIBILITY_ENABLED: '1', GNOME_ACCESSIBILITY: '1', QT_LINUX_ACCESSIBILITY_ALWAYS_ON: '1', XDG_SESSION_TYPE: 'wayland' }
delete launchEnv.NO_AT_BRIDGE
if (launchEnv.GTK_A11Y === 'none') delete launchEnv.GTK_A11Y
/** Starts one shell command line on the seat through helpers/launcher.py, detached. */
export async function launch(command) {
  const ready = await ensureAgentSeat()
  Object.assign(launchEnv, ready, { DISPLAY })
  await announceAssistiveTechnology(ready)
  spawn('python3', [LAUNCHER, command], { env: launchEnv, detached: true, stdio: 'ignore' }).unref()
}

export function close() { a11yWorker.close(); seatWorker.close(); directWorker.close() }
