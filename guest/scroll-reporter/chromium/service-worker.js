// Connects the page reporters (content.js) to caboose-display through the native host
// com.caboose.scroll. Reports go out from whichever tab sent them; bind, unbind and target
// messages go to the tab that reported last, the visible one. Frame numbers continue
// across tabs, so a tag value is not reused by a tab that becomes visible again.
const HOST = 'com.caboose.scroll'

let native = null
let retry = null
let bind = null
let reporter = null
let lastFrame = 0
const tabs = new Set()

function connectNative() {
  retry = null
  try {
    native = chrome.runtime.connectNative(HOST)
  } catch {
    native = null
    retry = setTimeout(connectNative, 5000)
    return
  }
  native.onMessage.addListener(message => {
    if (message.type === 'bind') bind = message
    else if (message.type === 'unbind') bind = null
    else if (message.type !== 'target' && message.type !== 'zoom') return
    try {
      reporter?.postMessage(message)
    } catch {}
  })
  native.onDisconnect.addListener(() => {
    native = null
    bind = null
    for (const tab of tabs) {
      try {
        tab.postMessage({ type: 'unbind' })
      } catch {}
    }
    if (!retry) retry = setTimeout(connectNative, 5000)
  })
}

// Zoom and pan the visual viewport the way a trackpad does, through the tab's debugger
// (Chromium runs with --silent-debugger-extension-api, so no banner shows). A tab whose
// DevTools hold the debugger is not zoomed; the reporter is answered either way.
const debugged = new Set()
chrome.debugger.onDetach.addListener(source => debugged.delete(source.tabId))

async function viewport(tabId, message) {
  const target = { tabId }
  if (!debugged.has(tabId)) {
    await chrome.debugger.attach(target, '1.3')
    debugged.add(tabId)
  }
  if (message.type === 'pinch') {
    await chrome.debugger.sendCommand(target, 'Input.synthesizePinchGesture', {
      x: message.x, y: message.y, scaleFactor: message.factor, relativeSpeed: 100000, gestureSourceType: 'mouse',
    })
  } else {
    await chrome.debugger.sendCommand(target, 'Input.dispatchMouseEvent', {
      type: 'mouseWheel', x: message.x, y: message.y, deltaX: message.dx, deltaY: message.dy,
    })
  }
}

chrome.runtime.onConnect.addListener(port => {
  if (port.name !== 'scroll') return
  tabs.add(port)
  port.onDisconnect.addListener(() => {
    tabs.delete(port)
    if (reporter === port) reporter = null
  })
  port.onMessage.addListener(message => {
    if (message?.type === 'visible') {
      reporter = port
      port.postMessage({ type: 'base', frame: (lastFrame + 1) & 0xffff })
      if (bind) port.postMessage(bind)
    } else if (message?.type === 'pinch' || message?.type === 'pan') {
      const tabId = port.sender?.tab?.id
      if (tabId === undefined) return
      viewport(tabId, message).catch(() => {}).finally(() => {
        if (message.type === 'pinch') {
          try {
            port.postMessage({ type: 'zoomed', seq: message.seq })
          } catch {}
        }
      })
    } else if (message?.type === 'report') {
      if (reporter !== port) {
        reporter = port
        if (bind) port.postMessage(bind)
      }
      lastFrame = message.frame
      if (!native && !retry) connectNative()
      try {
        native?.postMessage(message)
      } catch {}
    }
  })
})

connectNative()
