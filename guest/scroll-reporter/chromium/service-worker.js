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
    else if (message.type !== 'target') return
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
