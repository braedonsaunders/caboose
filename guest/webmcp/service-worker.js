// Caboose WebMCP, service worker: holds the connection to the native host
// (caboose-webmcp-host.py), through which desktop MCP asks for the tools of the browser's
// active tab and calls them. Each request is { id, op: "tools" | "call", name?, args? }; each
// reply { id, ok, result? | error? }.
const HOST = 'com.caboose.webmcp'
let port

function connect() {
  port = chrome.runtime.connectNative(HOST)
  port.onMessage.addListener(async request => {
    const reply = await answer(request).catch(error => ({ ok: false, error: String(error?.message ?? error) }))
    port?.postMessage({ id: request.id, ...reply })
  })
  // The host ends with the browser; a host that failed to start is tried again shortly.
  port.onDisconnect.addListener(() => { port = undefined; setTimeout(connect, 5000) })
}

async function answer(request) {
  const [tab] = await chrome.tabs.query({ active: true, lastFocusedWindow: true })
  if (!tab?.id) return { ok: false, error: 'no active tab' }
  const reply = await chrome.tabs.sendMessage(tab.id, { op: request.op, name: request.name, args: request.args }, { frameId: 0 })
    .catch(() => ({ ok: false, error: 'this page offers no tools (a browser page, or one still loading)' }))
  return reply ?? { ok: false, error: 'the page did not answer' }
}

connect()
