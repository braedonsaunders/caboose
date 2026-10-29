// caboose-app: the relay between an app's page and the native bridge. It runs in its own
// script world in the top frame only; the page cannot see this world's objects or the
// bridge's message handler, and frames get neither. Requests arrive as window messages
// whose source is the top window itself, so a frame cannot post one. Each request carries
// this document's random token; the runtime answers only the document it loaded last.
(() => {
  const handler = window.webkit.messageHandlers.caboose
  const token = Array.from(crypto.getRandomValues(new Uint8Array(16)), b => b.toString(16).padStart(2, '0')).join('')
  // Register even a page that makes no API calls, so edits and disconnects reach it.
  handler.postMessage(JSON.stringify({ document: token, method: '__caboose.ready', params: {} })).catch(() => {})
  window.addEventListener('message', event => {
    if (event.source !== window || event.origin !== location.origin) return
    const data = event.data
    if (!data || typeof data !== 'object' || data.caboose !== 'request' || !Number.isSafeInteger(data.id)) return
    let request
    try {
      request = JSON.stringify({ document: token, id: data.id, method: String(data.method), params: data.params ?? {} })
    } catch {
      window.postMessage({ caboose: 'reply', id: data.id, ok: false, error: 'The request could not be serialized' }, '*')
      return
    }
    handler.postMessage(request).then(
      answer => window.postMessage({ caboose: 'reply', id: data.id, ...JSON.parse(answer) }, '*'),
      error => window.postMessage({ caboose: 'reply', id: data.id, ok: false, error: String(error?.message ?? error) }, '*'))
  })
  // The runtime calls this, in this world, with process output and exits.
  Object.defineProperty(globalThis, '__cabooseEvent', {
    value: json => window.postMessage({ caboose: 'event', ...JSON.parse(json) }, '*'),
  })
})()
