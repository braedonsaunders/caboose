// Pure helpers shared by the content script, the service worker and selftest.mjs.
// Classic script: it defines globalThis.CabooseMedia (in a content script's isolated
// world, so pages cannot see or change it).
;(root => {
  /** The media id format; it travels unencoded in the host's URL paths. */
  const ID_PATTERN = /^[A-Za-z0-9._-]{1,64}$/
  function parse(value) {
    try { return new URL(value) } catch { return undefined }
  }

  function isHttp(value) {
    const url = typeof value === 'string' ? parse(value) : undefined
    return Boolean(url && (url.protocol === 'http:' || url.protocol === 'https:'))
  }

  /**
   * How the phone can take a video, the same way for every site: a plain http(s) source
   * (an HLS playlist or a file) plays natively from its URL; a stream the page assembles
   * itself (a blob: MediaSource) is handed over as its page, which the phone opens. data:
   * and MediaStream sources (calls, cameras) return undefined.
   */
  function classify(pageUrl, currentSrc) {
    if (isHttp(currentSrc)) return { kind: /\.m3u8$/i.test(parse(currentSrc).pathname) ? 'hls' : 'video', src: currentSrc }
    if (typeof currentSrc === 'string' && currentSrc.startsWith('blob:') && isHttp(pageUrl)) return { kind: 'page' }
    return undefined
  }

  /** A title without control characters or an unread-count prefix, at most 300 characters. */
  function cleanTitle(title) {
    if (typeof title !== 'string') return ''
    return title.replace(/[\u0000-\u001f\u007f]/g, ' ').replace(/^\(\d+\)\s+/, '').trim().slice(0, 300)
  }

  /** Seconds, or null for a live stream or a duration not yet known. */
  function duration(value) {
    return typeof value === 'number' && Number.isFinite(value) && value >= 0 ? value : null
  }

  root.CabooseMedia = { ID_PATTERN, isHttp, classify, cleanTitle, duration }
})(globalThis)
