#!/usr/bin/env node
// caboose-desktop-mcp — lets an agent see and drive GUI apps on the agent seat, its own
// Caboose Display, so it never touches the owner's display. An MCP server over stdio
// (newline-delimited JSON-RPC 2.0), with no dependencies beyond node: and two helpers beside
// this file: a11y.py (the accessibility tree, through python3 and AT-SPI) and seat.py (the
// seat's windows, pointer, keyboard and pictures, through its control socket). Wayland and
// X11 applications are driven alike. caboose-agentd gives it to every ACP agent in
// session/new, and answers the agent's permission requests itself.
import { spawn } from 'node:child_process'
import { mkdtemp, readFile, rm } from 'node:fs/promises'
import { appendFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { fileURLToPath } from 'node:url'
import { createInterface } from 'node:readline'
import { createConnection } from 'node:net'
import { mkdirSync, readFileSync, writeFileSync, renameSync } from 'node:fs'
import { Worker } from './worker.mjs'
import { Observer } from './observation.mjs'
import { controlAlive, ensureAgentSeat } from './ensure-agent-seat.mjs'

const DISPLAY = process.env.CABOOSE_AGENT_DISPLAY ?? ':101'
const env = { ...process.env, DISPLAY }
const PROTOCOL = '2025-06-18'
// CABOOSE_DESKTOP_TRACE: a file that gets one line per tool call (tool, milliseconds, reply size).
const TRACE = process.env.CABOOSE_DESKTOP_TRACE
// CABOOSE_DESKTOP_PAGE_TOOLS=0 leaves page tools out, to measure the accessibility path alone.
const PAGE_TOOLS = process.env.CABOOSE_DESKTOP_PAGE_TOOLS !== '0'
// Installed side by side: /opt/caboose/desktop-mcp.mjs, a11y.py and seat.py.
const A11Y = fileURLToPath(new URL('./a11y.py', import.meta.url))
const SEAT = fileURLToPath(new URL('./seat.py', import.meta.url))
const LAUNCHER = fileURLToPath(new URL('./launcher.py', import.meta.url))
// What a launched app needs to build its accessibility tree: GTK's bridge must not be
// switched off (NO_AT_BRIDGE, GTK_A11Y=none), Chromium and Electron read
// ACCESSIBILITY_ENABLED, Gecko GNOME_ACCESSIBILITY, Qt QT_LINUX_ACCESSIBILITY_ALWAYS_ON.
// The seat is a Wayland session; saying so makes Chromium and Electron run as Wayland
// clients, whose fields take the seat's text and whose windows place their controls exactly.
const launchEnv = { ...env, ACCESSIBILITY_ENABLED: '1', GNOME_ACCESSIBILITY: '1', QT_LINUX_ACCESSIBILITY_ALWAYS_ON: '1', XDG_SESSION_TYPE: 'wayland' }
delete launchEnv.NO_AT_BRIDGE
if (launchEnv.GTK_A11Y === 'none') delete launchEnv.GTK_A11Y

// Three tools, kept short: their definitions go to the model on every turn.
const tools = [
  {
    name: 'look',
    description: 'The focused window\'s controls from its accessibility tree, one per line: id role "name" = value [states], '
      + 'and in a browser the page\'s tools. find: only controls whose name contains it. text: also the window\'s readable text '
      + '(documents, pages, terminals). windows: every window, with its id and position. ocr: also the words read from the '
      + 'window\'s pixels with their positions, for areas the controls leave out (icon views, canvases).',
    inputSchema: { type: 'object', properties: { find: { type: 'string' }, text: { type: 'boolean' }, windows: { type: 'boolean' }, ocr: { type: 'boolean' } } },
  },
  {
    name: 'act',
    description: 'Run steps in order, stopping at the first failure; then reply with what changed (+ added, ~ changed, - removed '
      + 'controls; windows opened or closed). Put every step you already know in one call; a control in a dialog that an earlier '
      + 'step opens can be named instead of given by id ({"name":"Save","role":"button"}). A step is one of: {"press":id} '
      + '{"set":id,"text":t} replaces a field\'s text (plain; type keeps formatting), {"key":"ctrl+s"}, {"type":t}, {"click":[x,y],"button":1-3,"count":1-3}, '
      + '{"scroll":[x,y],"dy":n}, {"drag":[x1,y1,x2,y2]}, {"focus":window}, {"launch":"command"}, '
      + '{"tool":name,"args":{...}} calls a page tool, {"run":routine,"texts":[...]} replays a saved routine. Steps wait for '
      + 'the app to react; {"wait":ms} is rarely needed. save:name, once a task is done, keeps '
      + 'its steps as a routine of the application, replayable later with other texts.',
    inputSchema: { type: 'object', properties: { steps: { type: 'array', items: { type: 'object' } }, save: { type: 'string' } }, required: ['steps'] },
  },
  {
    name: 'screenshot',
    description: 'A picture of the seat, or of one window. Only for what the controls do not tell; coordinates are its pixels. '
      + 'marks: number the controls on it.',
    inputSchema: { type: 'object', properties: { window: { type: 'integer' }, marks: { type: 'boolean' } } },
  },
]

function int(value, name) {
  if (!Number.isInteger(value) || value < -100000 || value > 100000) throw new Error(`${name} must be an integer`)
  return String(value)
}

function text(value, name, max) {
  if (typeof value !== 'string' || !value.trim()) throw new Error(`${name} must be a non-empty string`)
  if (value.length > max) throw new Error(`${name} must be at most ${max} characters`)
  return value
}

const observer = new Observer()
const a11yWorker = new Worker(A11Y, [`--display=${DISPLAY}`], 30_000)
const seatWorker = new Worker(SEAT)
let seatEnvironment
// These tools are the seat's assistive technology, and say so on its accessibility bus as a
// screen reader does: Chromium, Electron and other toolkits that build their full tree only
// for one then expose it to applications started afterwards.
function announceAssistiveTechnology(seatEnv) {
  const child = spawn('gdbus', ['call', '--session', '--dest', 'org.a11y.Bus', '--object-path', '/org/a11y/bus', '--method',
    'org.freedesktop.DBus.Properties.Set', 'org.a11y.Status', 'ScreenReaderEnabled', '<true>'], { env: { ...env, ...seatEnv }, stdio: 'ignore' })
  child.on('error', () => {})
  return new Promise(resolve => { child.on('exit', resolve); child.on('error', resolve) })
}
async function workerRequest(worker, request) {
  const ready = await ensureAgentSeat()
  if (ready !== seatEnvironment) {
    a11yWorker.close()
    seatWorker.close()
    seatEnvironment = ready
    await announceAssistiveTechnology(ready)
  }
  Object.assign(env, ready, { DISPLAY })
  try {
    const answer = await worker.request(request, env)
    if (answer.error) throw new Error(answer.error)
    return answer
  } catch (error) {
    if (!await controlAlive(env)) ensureAgentSeat.invalidate()
    throw error
  }
}
async function a11y(command, options) {
  if (command === 'act') { actedAt = Number(process.hrtime.bigint() / 1000n); typed = options?.action === 'set-text' }
  const answer = await workerRequest(a11yWorker, { op: command, ...options })
  return [{ type: 'text', text: JSON.stringify(answer) }]
}
async function seat(...args) { return workerRequest(seatWorker, { args }) }

const BUTTONS = { 1: 'left', 2: 'middle', 3: 'right' }

// The display as the observer renders it: everything (`full`), or what changed since the last time.
let lastState
async function view(full) {
  let state = JSON.parse((await a11y('elements', {}))[0].text)
  let listing = await seat('windows')
  // A window that has just opened may not be in its application's tree yet, and a read that
  // raced the focus change describes the window before: read again, for up to 1.5 s, until
  // the read is of the focused window and, for one not seen before, shows controls.
  const stale = () => {
    // The read describes the window an open menu or tooltip belongs to, as a11y.py does.
    let focused = listing.windows.find(w => w.id === listing.focused)
    for (let hops = 0; focused?.kind === 'popup' && focused.parent != null && hops < 8; hops++)
      focused = listing.windows.find(w => w.id === focused.parent) ?? focused
    if (!focused) return false
    if ((state.window?.title ?? '') !== (focused.title ?? '')) return true
    return !(state.elements ?? []).length && !observer.seen.has(listing.focused)
  }
  const deadline = performance.now() + 1500
  while (performance.now() < deadline && stale()) {
    await new Promise(resolve => setTimeout(resolve, 100))
    state = JSON.parse((await a11y('elements', {}))[0].text)
    listing = await seat('windows')
  }
  lastState = state
  return observer.render(listing, state, { full })
}

// A window with no accessibility tree (SDL, games, custom-drawn toolkits): its picture, and the
// words OCR finds in it (tesseract, when installed) as lines with their centres in seat
// coordinates. Marked as read from pixels.
async function pixelFallback() {
  const listing = await seat('windows')
  const window = listing.windows.find(w => w.id === listing.focused)
  if (!window) return []
  const dir = await mkdtemp(join(tmpdir(), 'caboose-shot-'))
  try {
    const file = join(dir, 'window.png')
    const shot = await seat('screenshot', '--out', file, '--window', String(window.id))
    const png = await readFile(file)
    const parts = [{ type: 'text', text: `No accessibility tree in ${window.kind} ${window.id}: its picture follows (read from pixels).` },
      { type: 'image', data: png.toString('base64'), mimeType: 'image/png' }]
    const words = await ocr(file, shot.rect, png.readUInt32BE(16), png.readUInt32BE(20))
    if (words) parts.push({ type: 'text', text: `Text read from pixels (OCR; x,y are seat coordinates of each line's centre):\n${words}` })
    return parts
  } finally {
    await rm(dir, { recursive: true, force: true })
  }
}
// The focused window's words read from its pixels (OCR), with their centres in seat coordinates.
async function windowWords() {
  const listing = await seat('windows')
  const window = listing.windows.find(w => w.id === listing.focused)
  if (!window) return 'No window has the keyboard.'
  const dir = await mkdtemp(join(tmpdir(), 'caboose-shot-'))
  try {
    const file = join(dir, 'window.png')
    const shot = await seat('screenshot', '--out', file, '--window', String(window.id))
    const png = await readFile(file)
    const words = await ocr(file, shot.rect, png.readUInt32BE(16), png.readUInt32BE(20))
    return words ? `Text read from pixels (OCR; x,y are seat coordinates of each line's centre):\n${words}` : 'No text was read from pixels.'
  } finally {
    await rm(dir, { recursive: true, force: true })
  }
}
// Scrolled areas the application draws but leaves out of its tree (a11y.py's `unread`: a
// list or icon view a toolkit does not expose): their words read from the window's pixels.
async function unreadWords(regions) {
  const listing = await seat('windows')
  const window = listing.windows.find(w => w.id === listing.focused)
  if (!window) return ''
  const dir = await mkdtemp(join(tmpdir(), 'caboose-shot-'))
  try {
    const file = join(dir, 'window.png')
    const shot = await seat('screenshot', '--out', file, '--window', String(window.id))
    const png = await readFile(file)
    const [x0, y0, w, h] = shot.rect ?? [0, 0, png.readUInt32BE(16), png.readUInt32BE(20)]
    const sx = png.readUInt32BE(16) / w, sy = png.readUInt32BE(20) / h
    const lines = []
    for (const [index, [x, y, rw, rh]] of regions.entries()) {
      const crop = { x: Math.max(0, Math.round((x - x0) * sx)), y: Math.max(0, Math.round((y - y0) * sy)), w: Math.round(rw * sx), h: Math.round(rh * sy) }
      if (crop.w < 8 || crop.h < 8) continue
      const out = join(dir, `region-${index}.png`)
      const done = await new Promise(resolve => {
        const child = spawn('convert', [file, '-crop', `${crop.w}x${crop.h}+${crop.x}+${crop.y}`, '+repage', '-colorspace', 'Gray', '-resize', '200%', out], { stdio: 'ignore' })
        child.on('error', () => resolve(false))
        child.on('close', code => resolve(code === 0))
      })
      if (!done) continue
      const words = await read(out, [x, y, rw, rh], crop.w * 2, crop.h * 2)
      if (words) lines.push(`In ${x},${y},${rw}x${rh}, drawn but not exposed by the application (read from pixels; x,y are each line's centre):\n${words}`)
    }
    return lines.join('\n')
  } finally {
    await rm(dir, { recursive: true, force: true })
  }
}
// Small interface text reads better enlarged and in grey (ImageMagick, where installed), and
// as sparse text rather than a page (tesseract --psm 11).
function enlarge(file) {
  return new Promise(resolve => {
    const out = file.replace(/\.png$/, '-x2.png')
    const child = spawn('convert', [file, '-colorspace', 'Gray', '-resize', '200%', out], { stdio: 'ignore' })
    child.on('error', () => resolve(null))
    child.on('close', code => resolve(code === 0 ? out : null))
  })
}
async function ocr(file, rect, width, height) {
  const enlarged = await enlarge(file)
  return read(enlarged ?? file, rect, enlarged ? width * 2 : width, enlarged ? height * 2 : height)
}
function read(file, rect, width, height) {
  return new Promise(resolve => {
    const child = spawn('tesseract', [file, '-', '--psm', '11', 'tsv'], { stdio: ['ignore', 'pipe', 'ignore'] })
    let out = ''
    child.stdout.on('data', chunk => { out += chunk })
    child.on('error', () => resolve(''))
    child.on('close', () => {
      const [x0, y0, w, h] = rect ?? [0, 0, width, height]
      const sx = w / width, sy = h / height
      const lines = new Map()
      for (const row of out.split('\n').slice(1)) {
        const f = row.split('\t')
        // Words only: textures and icons read as stray symbols at low confidence. A short
        // name with digits ("p1") counts when it is read with high confidence.
        if (f.length < 12 || Number(f[10]) < 70 || !(/[\p{L}]{3,}|\p{N}{2,}/u.test(f[11]) || (Number(f[10]) >= 85 && /\p{L}[\p{L}\p{N}]|\p{N}\p{L}/u.test(f[11])))) continue
        const key = `${f[2]}.${f[3]}.${f[4]}`
        const line = lines.get(key) ?? { words: [], left: Infinity, top: Infinity, right: 0, bottom: 0 }
        line.words.push(f[11].trim())
        line.left = Math.min(line.left, +f[6]); line.top = Math.min(line.top, +f[7])
        line.right = Math.max(line.right, +f[6] + +f[8]); line.bottom = Math.max(line.bottom, +f[7] + +f[9])
        lines.set(key, line)
      }
      resolve([...lines.values()].slice(0, 80).map(l => `${JSON.stringify(l.words.join(' '))} at ${Math.round(x0 + (l.left + l.right) / 2 * sx)},${Math.round(y0 + (l.top + l.bottom) / 2 * sy)}`).join('\n'))
    })
  })
}
const element = id => observer.resolve(text(id, 'id', 500))

// Page tools (guest/webmcp): the Caboose WebMCP extension's native host listens beside the
// browser process that owns the window, at $XDG_RUNTIME_DIR/caboose-webmcp/<pid>.sock.
function pageRequest(pid, request, timeout = 25_000) {
  const path = join(env.XDG_RUNTIME_DIR || `/run/user/${process.getuid()}`, 'caboose-webmcp', `${pid}.sock`)
  return new Promise((resolve, reject) => {
    const socket = createConnection(path)
    let data = ''
    const timer = setTimeout(() => { socket.destroy(); reject(new Error('the page did not answer')) }, timeout)
    socket.on('connect', () => socket.write(JSON.stringify(request) + '\n'))
    socket.on('data', chunk => {
      data += chunk
      if (!data.includes('\n')) return
      clearTimeout(timer); socket.end()
      try { resolve(JSON.parse(data.split('\n')[0])) } catch { reject(new Error('invalid page reply')) }
    })
    socket.on('error', error => { clearTimeout(timer); reject(error) })
  })
}
async function focusedPid() {
  const listing = await seat('windows')
  return listing.windows.find(w => w.id === listing.focused)?.pid
}
const schemaLine = schema => Object.entries(schema?.properties ?? {}).map(([key, p]) =>
  `${key}${(schema.required ?? []).includes(key) ? '' : '?'}: ${p.enum ? p.enum.slice(0, 12).map(v => JSON.stringify(v)).join('|') + (p.enum.length > 12 ? '|…' : '') : p.type ?? 'any'}`).join(', ')
// The focused browser tab's tools as lines, or '' where there are none to offer.
async function pageTools() {
  if (!PAGE_TOOLS) return ''
  const pid = await focusedPid()
  if (!pid) return ''
  let reply
  try { reply = await pageRequest(pid, { op: 'tools' }, 5000) } catch { return '' }
  if (!reply.ok || !reply.result?.tools?.length) return ''
  return [`Page tools (${reply.result.title || reply.result.url}):`,
    ...reply.result.tools.map(t => `${t.name}(${schemaLine(t.inputSchema)})${t.source === 'derived' ? ' [derived]' : ''} — ${String(t.description ?? '').slice(0, 200)}`)].join('\n')
}
const resultText = result => (result?.content ?? []).map(part => part.text ?? (part.type ? `[${part.type}]` : '')).join(' ').slice(0, 4000) || JSON.stringify(result ?? null).slice(0, 4000)

function windowLines(windows) {
  return windows.length ? windows.map(w => `${w.kind} ${w.id} ${JSON.stringify(w.title ?? '')} (${w.app_id ?? 'unknown app'})`
    + `${w.parent != null ? ` of ${w.parent}` : ''} at ${w.rect.join(',')}${w.focused ? ', focused' : ''}`).join('\n') : 'No windows are open on the agent seat.'
}

// When the last action went in, on the compositor's clock (CLOCK_MONOTONIC): the next
// settled observation waits for the seat to react to it.
let actedAt, typed = false
let lastTiming = []
async function changes() {
  // A text edit is processed asynchronously (completion, validation): wait for the window to
  // go quiet. After a press, the first reaction is enough for an accessibility read.
  await seat('settle', typed ? 'quiet' : 'react', ...(actedAt === undefined ? [] : [String(actedAt)]))
  actedAt = undefined; typed = false
  return view(false)
}

// The window an element id names must still have the keyboard (or own the open menu that does).
async function inFocusedWindow(id) {
  const listing = await seat('windows')
  let focused = listing.focused
  const seen = new Set()
  while (!seen.has(focused)) {
    seen.add(focused)
    const window = listing.windows.find(w => w.id === focused)
    if (window?.kind !== 'popup' || window.parent == null) break
    focused = window.parent
  }
  if (parseInt(id.split('-')[0], 16) !== focused) throw new Error('stale id: the focused window changed, so nothing was done; look, then retry with its ids (safe to retry)')
}

// X keysym names of the printable ASCII characters that are not their own name.
const KEYSYMS = { ' ': 'space', '!': 'exclam', '"': 'quotedbl', '#': 'numbersign', '$': 'dollar', '%': 'percent', '&': 'ampersand',
  "'": 'apostrophe', '(': 'parenleft', ')': 'parenright', '*': 'asterisk', '+': 'plus', ',': 'comma', '-': 'minus', '.': 'period',
  '/': 'slash', ':': 'colon', ';': 'semicolon', '<': 'less', '=': 'equal', '>': 'greater', '?': 'question', '@': 'at',
  '[': 'bracketleft', '\\': 'backslash', ']': 'bracketright', '^': 'asciicircum', '_': 'underscore', '`': 'grave',
  '{': 'braceleft', '|': 'bar', '}': 'braceright', '~': 'asciitilde', '\n': 'Return', '\t': 'Tab' }

const point = (value, name, size) => {
  if (!Array.isArray(value) || value.length !== size) throw new Error(`${name} must be [${size === 2 ? 'x,y' : 'x1,y1,x2,y2'}]`)
  return value.map((v, i) => int(v, `${name}[${i}]`))
}

// An id that no longer resolves did nothing: say so, so a caller knows a retry is safe.
async function stale(action) {
  try { return await action() } catch (error) {
    if (/element not found/.test(error.message)) throw new Error('stale id: the control changed or is gone, so nothing was done; look, then retry with its new id (safe to retry)')
    throw error
  }
}

// One act step; returns a note for the reply, if any.
async function step(s) {
  if (!s || typeof s !== 'object') throw new Error('a step is an object such as {"press":"e3"}')
  if ('press' in s || 'set' in s) {
    const target = 'press' in s ? s.press : s.set
    // A control named rather than given by id is found when the step runs, in whatever window
    // has focus then, so one act can go through a dialog that the steps before it open.
    let id
    if (target && typeof target === 'object') {
      // The accessibility tree can still describe the window that had focus a moment ago (a
      // dialog an earlier step opened is mapping): look again until the name is in the window
      // that has focus.
      const deadline = performance.now() + 1500
      for (;;) {
        id = await byName(target)
        try { await inFocusedWindow(id); break } catch (error) {
          if (performance.now() > deadline) throw error
          await new Promise(resolve => setTimeout(resolve, 100))
        }
      }
    } else {
      id = element(target)
      await inFocusedWindow(id)
    }
    if ('press' in s) { await stale(() => a11y('act', { element: id, action: 'press' })); return }
    if (typeof s.text !== 'string' || s.text.length > 100_000) throw new Error('set needs text, a string of at most 100000 characters')
    const { note } = JSON.parse((await stale(() => a11y('act', { element: id, action: 'set-text', text: s.text })))[0].text)
    return note
  }
  actedAt = Number(process.hrtime.bigint() / 1000n)
  if ('key' in s) {
    if (typeof s.key !== 'string' || !/^[A-Za-z0-9_+]+$/.test(s.key)) throw new Error('key must look like "ctrl+s" or "Return"')
    await seat('key', '--', s.key)
  } else if ('type' in s) {
    if (typeof s.type !== 'string') throw new Error('type must be a string')
    typed = true
    // Text on the keyboard's layout goes in as key presses, in order with the steps around it;
    // anything else (accents, other scripts) as the input method's commit.
    const keys = [...s.type].map(c => KEYSYMS[c] ?? (/^[A-Za-z0-9]$/.test(c) ? c : null))
    if (s.type && keys.every(Boolean)) {
      for (let i = 0; i < keys.length; i += 200) await seat('key', '--', ...keys.slice(i, i + 200))
    } else await seat('type', '--', s.type)
  } else if ('click' in s) {
    const [x, y] = point(s.click, 'click', 2), button = s.button ?? 1, count = s.count ?? 1
    if (!BUTTONS[button]) throw new Error('button must be 1 (left), 2 (middle) or 3 (right)')
    if (![1, 2, 3].includes(count)) throw new Error('count must be 1, 2 or 3')
    await seat('click', x, y, '--button', BUTTONS[button], '--count', String(count))
  } else if ('scroll' in s) {
    const [x, y] = point(s.scroll, 'scroll', 2)
    const clamp = (value, name) => String(Math.max(-50, Math.min(50, Number(int(value ?? 0, name)))))
    await seat('scroll', x, y, clamp(s.dx, 'dx'), clamp(s.dy, 'dy'))
  } else if ('drag' in s) {
    await seat('drag', ...point(s.drag, 'drag', 4))
  } else if ('focus' in s) {
    if (!Number.isInteger(s.focus)) throw new Error('focus must be a window id')
    await seat('focus', String(s.focus))
  } else if ('wait' in s) {
    if (!Number.isInteger(s.wait) || s.wait < 10 || s.wait > 5000) throw new Error('wait must be 10–5000 ms')
    // At most that long, and no longer than the windows take to stop drawing: every step
    // already waits for the application's reaction, so a wait mostly lets a slow one finish.
    const until = performance.now() + s.wait
    let settled = true
    try { await seat('settle', 'quiet', ...(actedAt === undefined ? [] : [String(actedAt)])) } catch { settled = false }
    const left = settled ? Math.min(until - performance.now(), 200) : until - performance.now()
    if (left > 0) await new Promise(resolve => setTimeout(resolve, left))
  } else if ('tool' in s) {
    const name = text(s.tool, 'tool', 200)
    if (!PAGE_TOOLS) throw new Error('page tools are off (CABOOSE_DESKTOP_PAGE_TOOLS=0)')
    if (s.args !== undefined && (typeof s.args !== 'object' || s.args === null || Array.isArray(s.args))) throw new Error('args must be an object')
    const pid = await focusedPid()
    let reply
    try { reply = await pageRequest(pid, { op: 'call', name, args: s.args ?? {} }) } catch { throw new Error('the focused window offers no page tools') }
    if (!reply.ok) throw new Error(`${name}: ${reply.error}`)
    return `${name}: ${resultText(reply.result)}`
  } else if ('launch' in s) {
    const command = text(s.launch, 'launch', 2000)
    const ready = await ensureAgentSeat()
    Object.assign(launchEnv, ready, { DISPLAY })
    await announceAssistiveTechnology(ready)
    spawn('python3', [LAUNCHER, command], { env: launchEnv, detached: true, stdio: 'ignore' }).unref()
  } else throw new Error('unknown step; use press, set, key, type, click, scroll, drag, focus, wait, launch or tool')
}

// Routines: an act run that worked, kept per application with its controls named by role and
// name (ids do not outlive the server) and its texts as parameters, so a repeated task replays
// in one call. Stored in $XDG_STATE_HOME/caboose/routines.json of the agent's profile.
function routinesFile() {
  const state = env.XDG_STATE_HOME || join(env.HOME || '/tmp', '.local', 'state')
  return join(state, 'caboose', 'routines.json')
}
function loadRoutines() {
  try { return JSON.parse(readFileSync(routinesFile(), 'utf8')) } catch { return {} }
}
function saveRoutines(all) {
  const file = routinesFile()
  mkdirSync(join(file, '..'), { recursive: true })
  writeFileSync(file + '.tmp', JSON.stringify(all, null, 1))
  renameSync(file + '.tmp', file)
}
async function focusedApp() {
  const listing = await seat('windows')
  return listing.windows.find(w => w.id === listing.focused)?.app_id ?? ''
}
// The steps that have worked since the last save (the task so far), each control kept as
// { role, name } as it was read when the step ran.
let journal = []
function journalStep(s, ms = 0) {
  const out = { ...s, ms }
  for (const verb of ['press', 'set']) if (verb in s && typeof s[verb] !== 'object') {
    const described = observer.described.get(observer.resolve(String(s[verb])))
    if (!described) return
    out[verb] = described
  }
  journal.push(out)
}
// A routine from the journal, its texts as $1, $2, …
function asRoutine(steps) {
  let texts = 0
  return steps.filter(s => !('wait' in s) && !('launch' in s)).map(s => {
    const { ms, ...out } = s
    if ('text' in s) out.text = `$${++texts}`
    if ('type' in s) out.type = `$${++texts}`
    return out
  })
}
// A saved step for the window as it is: its control found again by role and name.
// The one control of the focused window with this name (and role, when given). A window that
// is still opening is read again, for up to 1.5 s.
async function byName({ name, role }) {
  if (typeof name !== 'string' || !name) throw new Error('a named control needs a name, e.g. {"name":"Save","role":"button"}')
  const deadline = performance.now() + 1500
  for (;;) {
    const { elements } = JSON.parse((await a11y('find', { query: name }))[0].text)
    const match = (elements ?? []).filter(e => (e.name ?? '').replace(/[\s:]+$/, '').toLowerCase() === name.replace(/[\s:]+$/, '').toLowerCase()
      && (!role || e.role === role || e.role.endsWith(` ${role}`)))
    if (match.length === 1) return match[0].id
    if (match.length > 1) throw new Error(`more than one ${role ?? 'control'} "${name}" in the window; use its id from look`)
    if (performance.now() > deadline) throw new Error(`no ${role ?? 'control'} "${name}" in the focused window`)
    await new Promise(resolve => setTimeout(resolve, 100))
  }
}

async function replayStep(s, texts) {
  const out = { ...s }
  for (const verb of ['press', 'set']) if (verb in s && typeof s[verb] === 'object') out[verb] = await byName(s[verb])
  for (const key of ['text', 'type']) if (typeof out[key] === 'string' && /^\$\d+$/.test(out[key])) {
    const value = texts[Number(out[key].slice(1)) - 1]
    if (typeof value !== 'string') throw new Error(`the routine needs text ${out[key]}`)
    out[key] = value
  }
  return out
}

const handlers = {
  async look({ find, text: withText = false, windows = false, ocr: withOcr = false } = {}) {
    const parts = []
    if (windows) parts.push(windowLines((await seat('windows')).windows))
    if (find !== undefined) {
      const { elements, note } = JSON.parse((await a11y('find', { query: text(find, 'find', 500) }))[0].text)
      const lines = (elements ?? []).map(e => observer.line(observer.short(e.id), e))
      parts.push(lines.length ? lines.join('\n') : (note ?? 'No control matches.'))
    } else {
      parts.push(await view(true))
      const tools = await pageTools()
      if (tools) parts.push(tools)
      // Routines of this application come first: one replays a whole task in a single act.
      const routines = Object.entries(loadRoutines()[await focusedApp().catch(() => '')] ?? {})
      if (routines.length) parts.unshift(routines.map(([name, r]) => {
        return `Routine ${JSON.stringify(name)}: ${r.steps.length} steps, about ${((r.ms ?? 300 * r.steps.length) / 1000).toFixed(1)} s in one call: `
          + `act {"steps":[{"run":${JSON.stringify(name)},"texts":[…]}]}, with texts in this order (last time ${JSON.stringify(r.texts ?? [])}). `
          + 'Use it when the task is the same.'
      }).join('\n'))
      if (lastState?.unread?.length) {
        const words = await unreadWords(lastState.unread).catch(() => '')
        if (words) parts.push(words)
      }
      if (lastState?.note && !(lastState.elements ?? []).length && lastState.window) {
        const pictured = await pixelFallback().catch(() => [])
        if (pictured.length) return [{ type: 'text', text: parts.join('\n') }, ...pictured]
      }
    }
    if (withText) {
      const { text: readable } = JSON.parse((await a11y('text', {}))[0].text)
      parts.push(`Text:\n${readable ?? ''}`)
    }
    if (withOcr) parts.push(await windowWords().catch(error => `No text could be read from pixels: ${error.message}`))
    return [{ type: 'text', text: parts.join('\n') }]
  },
  async act({ steps, observe = true, save }) {
    if (!Array.isArray(steps) || steps.length < 1 || steps.length > 30) throw new Error('steps must hold 1–30 steps')
    if (save !== undefined) text(save, 'save', 80)
    // A routine step stands for its saved steps, replayed against the window as it is.
    const expanded = []
    for (const s of steps) {
      if (s && typeof s === 'object' && 'run' in s) {
        const routine = loadRoutines()[await focusedApp()]?.[s.run]
        if (!routine) throw new Error(`no routine ${JSON.stringify(s.run)} for this application`)
        for (const r of routine.steps) expanded.push({ replay: r, texts: s.texts ?? [] })
      } else expanded.push(s)
    }
    steps = expanded
    let windowsBefore = null
    try { windowsBefore = new Set((await seat('windows')).windows.map(w => w.id)) } catch {}
    let done = 0, error
    const notes = []
    let after
    const timing = []
    for (const s of steps) {
      try {
        // Typed text reaches an application as an input method's commit, keys as key events,
        // and it may take them out of order: after typing, the next step waits until the
        // window has drawn it.
        if (after === 'type' && s && typeof s === 'object' && !('wait' in s)) {
          await seat('settle', 'quiet', ...(actedAt === undefined ? [] : [String(actedAt)]))
        }
        // A shortcut's command can run after the key event, once the application gets to it
        // (LibreOffice's ctrl+b): let it react before more input, or the text typed next can
        // arrive first.
        if (after === 'shortcut' && s && typeof s === 'object' && ('type' in s || 'key' in s)) {
          await seat('settle', 'react', ...(actedAt === undefined ? [] : [String(actedAt)]))
        }
        const began = performance.now()
        const run = s && s.replay ? await replayStep(s.replay, s.texts) : s
        const note = await step(run); if (note) notes.push(note); done++
        journalStep(s && s.replay ? { ...s.replay, ...(s.replay.text ? { text: run.text } : {}), ...(s.replay.type ? { type: run.type } : {}) } : s,
          Math.round(performance.now() - began))
        timing.push(`${Object.keys(s ?? {})[0]}:${Math.round(performance.now() - began)}`)
        after = s && typeof s === 'object' && 'type' in s ? 'type'
          : s && typeof s === 'object' && typeof s.key === 'string' && /(^|\+)(ctrl|alt|super|control|meta)\+/i.test(s.key) ? 'shortcut' : undefined
      } catch (e) { error = e.message; break }
    }
    let saved = ''
    if (save !== undefined && done === steps.length) {
      try {
        const all = loadRoutines(), app = await focusedApp()
        const kept = journal.filter(x => !('wait' in x) && !('launch' in x))
        const used = kept.flatMap(x => [x.text, x.type].filter(t => typeof t === 'string'))
        all[app] = { ...(all[app] ?? {}), [save]: { steps: asRoutine(journal), texts: used.map(t => t.slice(0, 60)), ms: kept.reduce((n, x) => n + (x.ms ?? 0), 0) + 300 * kept.length } }
        saveRoutines(all)
        journal = []
        saved = ` Saved as routine ${JSON.stringify(save)}.`
      } catch (e) { saved = ` Not saved: ${e.message}` }
    }
    const head = (done === steps.length ? (steps.length > 1 ? `Done ${done} steps.` : 'Done.') : `Did ${done} of ${steps.length}; stopped: ${error}`) + saved
    const content = [head + (notes.length ? ` (${notes.join('; ')})` : '')]
    if (observe) {
      const began = performance.now()
      try {
        let seen = await changes()
        // An application busy building a window (a first file chooser can take seconds) draws
        // nothing until it maps: after a press, key or click that changed nothing, wait a little
        // for a new window before saying so.
        if (seen === 'No change.' && windowsBefore && done && steps.slice(0, done).some(x => x && typeof x === 'object' && ('press' in x || 'key' in x || 'click' in x || 'replay' in x))) {
          const deadline = performance.now() + 2500
          while (performance.now() < deadline) {
            await new Promise(resolve => setTimeout(resolve, 100))
            if ((await seat('windows')).windows.some(w => !windowsBefore.has(w.id))) { seen = await changes(); break }
          }
        }
        content.push(seen)
      } catch (e) { content.push(`Could not read the window: ${e.message}`) }
      timing.push(`observe:${Math.round(performance.now() - began)}`)
    }
    lastTiming = timing
    return [{ type: 'text', text: content.join('\n') }]
  },
  async screenshot({ window, marks = false }) {
    if (window !== undefined && !Number.isInteger(window)) throw new Error('window must be a window id')
    if (typeof marks !== 'boolean') throw new Error('marks must be a boolean')
    const dir = await mkdtemp(join(tmpdir(), 'caboose-shot-'))
    try {
      const file = join(dir, 'seat.png')
      const shot = await seat('screenshot', '--out', file, ...(window === undefined ? [] : ['--window', String(window)]))
      let legend
      if (marks) {
        const state = JSON.parse((await a11y('elements', {}))[0].text)
        ;({ legend } = await seat('annotate', file, shot.rect, state.elements, window ?? null))
        legend = legend?.map(entry => `${entry.mark} ${observer.short(entry.id)} ${entry.role} ${JSON.stringify(entry.name ?? '')} at ${entry.center.join(',')}`)
      }
      return [{ type: 'image', data: (await readFile(file)).toString('base64'), mimeType: 'image/png' },
        ...(legend ? [{ type: 'text', text: legend.join('\n') }] : [])]
    } finally {
      await rm(dir, { recursive: true, force: true })
    }
  },
}

// How to use the tools, sent once to the agent when it connects.
const INSTRUCTIONS = 'Read the agent seat with look, act on controls by id, and batch known steps in one act; each act replies with what changed.'

function reply(id, result) { process.stdout.write(JSON.stringify({ jsonrpc: '2.0', id, result }) + '\n') }
function fail(id, code, message) { process.stdout.write(JSON.stringify({ jsonrpc: '2.0', id, error: { code, message } }) + '\n') }

async function handle(message) {
  const { id, method, params } = message
  if (method === 'initialize') {
    return reply(id, { protocolVersion: params?.protocolVersion ?? PROTOCOL, capabilities: { tools: {} },
      serverInfo: { name: 'caboose-desktop', version: '1.0.0' }, instructions: INSTRUCTIONS })
  }
  if (method === 'notifications/initialized' || id === undefined) return
  if (method === 'ping') return reply(id, {})
  if (method === 'tools/list') return reply(id, { tools })
  if (method === 'tools/call') {
    const handler = handlers[params?.name]
    if (!handler) return fail(id, -32602, `unknown tool ${params?.name}`)
    const started = performance.now()
    try {
      const content = await handler(params.arguments ?? {})
      reply(id, { content })
      if (TRACE) appendFileSync(TRACE, JSON.stringify({ tool: params.name, ms: Math.round(performance.now() - started), ...(params.name === 'act' ? { steps: lastTiming } : {}),
        chars: content.reduce((n, part) => n + (part.text?.length ?? 0), 0), images: content.filter(part => part.type === 'image').length }) + '\n')
    } catch (error) {
      reply(id, { content: [{ type: 'text', text: String(error?.stderr || error?.message || error).trim() }], isError: true })
    }
    return
  }
  fail(id, -32601, `method not found: ${method}`)
}

let queue = Promise.resolve()
const lines = createInterface({ input: process.stdin })
lines.on('line', line => {
  if (!line.trim()) return
  let message
  try { message = JSON.parse(line) } catch { return fail(null, -32700, 'parse error') }
  queue = queue.then(() => handle(message))
})

const close = () => { a11yWorker.close(); seatWorker.close() }
lines.on('close', () => { void queue.finally(close) })
process.on('SIGTERM', () => { close(); process.exit(0) })
process.on('SIGINT', () => { close(); process.exit(0) })
process.on('exit', close)
