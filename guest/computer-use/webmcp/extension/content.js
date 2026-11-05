// Caboose WebMCP, content script: carries the service worker's requests to page.js, which runs
// in the page's own world where document.modelContext lives, and its replies back.
chrome.runtime.onMessage.addListener((request, _sender, respond) => {
  const id = crypto.randomUUID()
  const timer = setTimeout(() => { window.removeEventListener('message', listen); respond({ ok: false, error: 'the page did not answer' }) }, 20000)
  function listen(event) {
    const message = event.data
    if (event.source !== window || !message || message.cabooseWebMCP !== 'reply' || message.id !== id) return
    clearTimeout(timer)
    window.removeEventListener('message', listen)
    respond({ ok: message.ok, result: message.result, error: message.error })
  }
  window.addEventListener('message', listen)
  window.postMessage({ cabooseWebMCP: 'request', id, op: request.op, name: request.name, args: request.args }, '*')
  return true
})
