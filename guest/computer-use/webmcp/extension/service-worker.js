// Caboose WebMCP, service worker: holds the connection to the native host
// (webmcp/host.py), through which the computer-use server asks for the tools of the browser's
// active tab and calls them, and works the browser's tabs (op "browser": tabs, activate, open,
// evaluate; evaluate through the DevTools protocol, chrome.debugger). Each request is
// { id, op: "tools" | "call" | "browser", name?, args? }; each reply { id, ok, result? | error? }.
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

async function allTabs() {
  return (await chrome.tabs.query({})).sort((a, b) => a.windowId - b.windowId || a.index - b.index)
}
function loaded(tabId, timeout = 15000) {
  return new Promise(resolve => {
    const done = () => { clearTimeout(timer); chrome.tabs.onUpdated.removeListener(listen); resolve() }
    const listen = (id, change) => { if (id === tabId && change.status === 'complete') done() }
    const timer = setTimeout(done, timeout)
    chrome.tabs.onUpdated.addListener(listen)
  })
}
async function browser(name, args = {}) {
  const [active] = await chrome.tabs.query({ active: true, lastFocusedWindow: true })
  if (name === 'tabs') {
    return (await allTabs()).map((t, index) => ({ index, title: t.title, url: t.url, active: t.id === active?.id }))
  }
  if (name === 'activate') {
    const tab = (await allTabs())[Number(args.index)]
    if (!tab) throw new Error('no tab with that index; browser.tabs lists them')
    await chrome.tabs.update(tab.id, { active: true }); await chrome.windows.update(tab.windowId, { focused: true })
    return `Switched to ${tab.title || tab.url}.`
  }
  if (name === 'open') {
    if (typeof args.url !== 'string' || !args.url) throw new Error('url is needed')
    const tab = args.new_tab || !active ? await chrome.tabs.create({ url: args.url }) : await chrome.tabs.update(active.id, { url: args.url })
    await loaded(tab.id)
    const now = await chrome.tabs.get(tab.id)
    return `Opened ${now.url}: ${now.title}`
  }
  if (name === 'evaluate') {
    if (typeof args.expression !== 'string' || !args.expression) throw new Error('expression is needed')
    if (!active?.id) throw new Error('no active tab')
    const target = { tabId: active.id }
    await chrome.debugger.attach(target, '1.3')
    try {
      const reply = await chrome.debugger.sendCommand(target, 'Runtime.evaluate',
        { expression: args.expression, returnByValue: true, awaitPromise: true, userGesture: true, timeout: 20000 })
      if (reply.exceptionDetails) throw new Error(reply.exceptionDetails.exception?.description ?? reply.exceptionDetails.text)
      return reply.result?.value ?? reply.result?.description ?? null
    } finally {
      await chrome.debugger.detach(target).catch(() => {})
    }
  }
  throw new Error(`no browser tool ${name}`)
}

async function answer(request) {
  if (request.op === 'browser') return { ok: true, result: await browser(request.name, request.args) }
  const [tab] = await chrome.tabs.query({ active: true, lastFocusedWindow: true })
  if (!tab?.id) return { ok: false, error: 'no active tab' }
  const reply = await chrome.tabs.sendMessage(tab.id, { op: request.op, name: request.name, args: request.args }, { frameId: 0 })
    .catch(() => ({ ok: false, error: 'this page offers no tools (a browser page, or one still loading)' }))
  return reply ?? { ok: false, error: 'the page did not answer' }
}

connect()
