// Pure helpers shared by the content script, the service worker and selftest.mjs.
// Classic script: it defines globalThis.CabooseMedia (in a content script's isolated
// world, so pages cannot see or change it).
;(root => {
  /** The media id format; it travels unencoded in the host's URL paths. */
  const ID_PATTERN = /^[A-Za-z0-9._-]{1,64}$/
  const VIDEO_ID = /^[A-Za-z0-9_-]{11}$/
  const YOUTUBE_HOST = /(^|\.)(youtube\.com|youtube-nocookie\.com)$/

  function parse(value) {
    try { return new URL(value) } catch { return undefined }
  }

  function isHttp(value) {
    const url = typeof value === 'string' ? parse(value) : undefined
    return Boolean(url && (url.protocol === 'http:' || url.protocol === 'https:'))
  }

  /** The YouTube video a page or embed frame shows, from its URL alone. */
  function youtubeVideoId(pageUrl) {
    const url = parse(pageUrl)
    if (!url || (url.protocol !== 'https:' && url.protocol !== 'http:')) return undefined
    const host = url.hostname.toLowerCase()
    const parts = url.pathname.split('/')
    let id
    if (host === 'youtu.be') id = parts[1]
    else if (YOUTUBE_HOST.test(host)) {
      if (url.pathname === '/watch') id = url.searchParams.get('v')
      else if (['embed', 'shorts', 'live', 'v'].includes(parts[1])) id = parts[2]
    }
    return id && VIDEO_ID.test(id) ? id : undefined
  }

  /**
   * What the phone can play: a YouTube video by id (its <video> plays an MSE blob, which
   * is fine because the phone plays the id, not the stream), or a plain http(s) source.
   * Every other blob:, data: or MediaStream source is unsupported and returns undefined.
   */
  function classify(pageUrl, currentSrc) {
    const src = isHttp(currentSrc) ? currentSrc : undefined
    const videoId = youtubeVideoId(pageUrl)
    if (videoId) return src ? { kind: 'youtube', videoId, src } : { kind: 'youtube', videoId }
    if (!src) return undefined
    return { kind: /\.m3u8$/i.test(parse(src).pathname) ? 'hls' : 'video', src }
  }

  /** A title without YouTube's unread count prefix or site suffix, at most 300 characters. */
  function cleanTitle(title) {
    if (typeof title !== 'string') return ''
    return title.replace(/[\u0000-\u001f\u007f]/g, ' ').replace(/^\(\d+\)\s+/, '').replace(/\s+-\s+YouTube$/, '').trim().slice(0, 300)
  }

  /** Seconds, or null for a live stream or a duration not yet known. */
  function duration(value) {
    return typeof value === 'number' && Number.isFinite(value) && value >= 0 ? value : null
  }

  root.CabooseMedia = { ID_PATTERN, isHttp, youtubeVideoId, classify, cleanTitle, duration }
})(globalThis)
