// A classic script in a page without <meta charset>: it runs, and the page's title arrives
// as UTF-8, both from the runtime's Content-Type header.
window.top.__frameTitle = document.title
// The frame posts a bridge request to the top window as if it were the page. The relay
// ignores it, because the message's source is this frame, so frame-mark is never created.
window.top.postMessage({ caboose: 'request', id: 424242, method: 'exec', params: { argv: ['touch', 'frame-mark'] } }, '*')
