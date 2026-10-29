// A frame posts a bridge request to the top window as if it were the page. The relay
// ignores it, because the message's source is this frame, so frame-mark is never created.
window.top.postMessage({ caboose: 'request', id: 424242, method: 'exec', params: { argv: ['touch', 'frame-mark'] } }, '*')
