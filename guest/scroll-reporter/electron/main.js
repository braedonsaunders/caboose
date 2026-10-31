// The Electron scroll reporter (docs/display.md, "Scroll reports"). caboose-display puts
// NODE_OPTIONS=--require <this file> in its launch environment, so Electron loads it into an
// application's main process; anywhere else (plain Node, an Electron renderer or utility
// process) it returns at once.
//
// For each window's web contents it attaches Electron's own debugger and runs the Chromium
// reporter (../chromium/core.js and content.js) in an isolated world of every document, as the
// extension does in Chromium. The reporter posts its reports through a binding of that world,
// and this process passes them to caboose-display's scroll socket, one connection per window,
// and sends bind, unbind and target messages back into the world.
'use strict'
if (!process.versions.electron || process.type !== 'browser') return

const fs = require('node:fs')
const net = require('node:net')
const path = require('node:path')

const WORLD = 'caboose-scroll'
const BINDING = '__cabooseScrollPost'
const MAX_MESSAGE = 1024 * 1024
const log = message => {
  if (process.env.CABOOSE_SCROLL_DEBUG === '1') process.stderr.write(`caboose-scroll: ${message}\n`)
}

/** The display instance's scroll socket, as the other reporters find it. */
function socketPath() {
  if (process.env.CABOOSE_SCROLL_SOCKET) return process.env.CABOOSE_SCROLL_SOCKET
  const runtime = process.env.XDG_RUNTIME_DIR
  const wayland = process.env.WAYLAND_DISPLAY || 'wayland-caboose-0'
  return runtime && !wayland.includes('/') ? path.join(runtime, 'caboose-display', wayland, 'scroll.sock') : null
}

let source
function reporterSource() {
  if (source === undefined) {
    const dir = path.join(__dirname, '..', 'chromium')
    try {
      source = ['core.js', 'content.js'].map(f => fs.readFileSync(path.join(dir, f), 'utf8')).join('\n')
    } catch (error) {
      log(`no reporter script: ${error.message}`)
      source = null
    }
  }
  return source
}

function frame(json) {
  const body = Buffer.from(json)
  const head = Buffer.alloc(4)
  head.writeUInt32LE(body.length)
  return Buffer.concat([head, body])
}

/** Splits a byte stream into whole messages' JSON. */
function framer(onMessage) {
  let buffer = Buffer.alloc(0)
  return chunk => {
    buffer = Buffer.concat([buffer, chunk])
    while (buffer.length >= 4) {
      const length = buffer.readUInt32LE(0)
      if (length > MAX_MESSAGE) throw new Error(`${length} byte message`)
      if (buffer.length < 4 + length) break
      onMessage(buffer.subarray(4, 4 + length).toString('utf8'))
      buffer = buffer.subarray(4 + length)
    }
  }
}

async function attach(contents) {
  const script = reporterSource()
  const where = socketPath()
  if (!script || !where) return
  const dbg = contents.debugger
  try {
    dbg.attach('1.3')
  } catch (error) {
    // Another debugger (its own DevTools) holds it: this window goes unreported.
    log(`cannot attach to ${contents.id}: ${error.message}`)
    return
  }
  let context = null
  let socket = null
  let closed = false
  const toPage = json => {
    if (context === null) return
    dbg.sendCommand('Runtime.evaluate', { expression: `globalThis.__cabooseScrollReceive?.(${json})`, contextId: context })
      .catch(() => {})
  }
  const open = () => {
    if (closed) return
    const s = net.connect(where)
    const read = framer(toPage)
    s.on('connect', () => {
      socket = s
      log(`window ${contents.id} connected to ${where}`)
    })
    s.on('data', chunk => {
      try {
        read(chunk)
      } catch (error) {
        log(error.message)
        s.destroy()
      }
    })
    s.on('error', () => {})
    s.on('close', () => {
      if (socket === s) {
        socket = null
        toPage(JSON.stringify({ type: 'unbind' }))
      }
      if (!closed) setTimeout(open, 1000)
    })
  }
  dbg.on('message', (_event, method, params) => {
    if (method === 'Runtime.executionContextCreated') log(`window ${contents.id} context ${params.context.id} "${params.context.name}"`)
    if (method === 'Runtime.exceptionThrown') log(`window ${contents.id}: ${params.exceptionDetails.exception?.description ?? params.exceptionDetails.text}`)
    if (method === 'Runtime.bindingCalled' && params.name === BINDING) {
      context = params.executionContextId
      try {
        const message = JSON.parse(params.payload)
        if (message.type === 'report') socket?.write(frame(params.payload))
        else if (message.type === 'pinch' || message.type === 'pan') viewport(message)
      } catch {}
    }
  })
  // Zoom and pan the visual viewport the way a trackpad does; a pinch is answered when done.
  const viewport = message => {
    const done = message.type === 'pinch'
      ? dbg.sendCommand('Input.synthesizePinchGesture', {
          x: message.x, y: message.y, scaleFactor: message.factor, relativeSpeed: 100000, gestureSourceType: 'mouse',
        })
      : dbg.sendCommand('Input.dispatchMouseEvent', {
          type: 'mouseWheel', x: message.x, y: message.y, deltaX: message.dx, deltaY: message.dy,
        })
    done.catch(() => {}).finally(() => {
      if (message.type === 'pinch') toPage(JSON.stringify({ type: 'zoomed', seq: message.seq }))
    })
  }
  dbg.on('detach', () => {
    closed = true
    socket?.destroy()
  })
  contents.once('destroyed', () => {
    closed = true
    socket?.destroy()
  })
  try {
    // Binding calls are delivered only while the Runtime domain is enabled.
    await dbg.sendCommand('Runtime.enable')
    await dbg.sendCommand('Runtime.addBinding', { name: BINDING, executionContextName: WORLD })
    await dbg.sendCommand('Page.enable')
    await dbg.sendCommand('Page.addScriptToEvaluateOnNewDocument', { source: script, worldName: WORLD, runImmediately: true })
  } catch (error) {
    log(`window ${contents.id}: ${error.message}`)
    return
  }
  open()
}

// NODE_OPTIONS modules run before Electron registers its own modules, so `electron` is looked
// up once the application's main script has run; no window exists before that. Nothing here
// may ever take the application down.
setImmediate(() => {
  try {
    const { app } = require('electron')
    app.on('web-contents-created', (_event, contents) => {
      // Windows and their browser views; not DevTools, background pages or <webview> guests.
      try {
        const type = contents.getType()
        if (type === 'window' || type === 'browserView') attach(contents).catch(error => log(error.message))
      } catch (error) {
        log(error.message)
      }
    })
  } catch (error) {
    log(`not reporting: ${error.message}`)
  }
})
