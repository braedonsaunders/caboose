// Runs in every http(s) frame. Reports each <video> this frame has seen play, with its
// position, to the service worker, which picks the one the phone is offered. Plays and
// pauses a video when the service worker relays a command from the host.
;(() => {
  if (globalThis.cabooseMediaContent) return
  globalThis.cabooseMediaContent = true
  const { classify, cleanTitle, duration } = globalThis.CabooseMedia
  const HEARTBEAT_MS = 5000
  // Ids are per document: a reload or navigation never reuses an id for another video.
  const nonce = Math.random().toString(36).slice(2, 10) || 'x'
  let counter = 0
  /** Videos this frame has reported: element → { key, ident }. */
  const tracked = new Map()
  let heartbeat

  function send(message) {
    try {
      chrome.runtime.sendMessage(message).catch(() => {})
    } catch {
      // The extension was reloaded or removed; this copy of the script is orphaned.
      clearInterval(heartbeat)
    }
  }

  /** Muted looping videos are page decoration (hero backgrounds, previews), not media. */
  function decorative(video) { return video.muted && video.loop }

  /** A YouTube ad plays in the same element; the phone is offered the video, not the ad. */
  function adShowing(video) {
    const player = video.closest('.html5-video-player')
    return Boolean(player && player.classList.contains('ad-showing'))
  }

  function describe(video) {
    if (!video.isConnected || decorative(video) || adShowing(video)) return undefined
    const source = classify(location.href, video.currentSrc)
    if (!source) return undefined
    const metadata = navigator.mediaSession && navigator.mediaSession.metadata
    return {
      ...source,
      title: cleanTitle((metadata && metadata.title) || document.title),
      frameUrl: location.href,
      position: Number.isFinite(video.currentTime) ? Math.max(0, video.currentTime) : 0,
      duration: duration(video.duration),
      paused: video.paused,
      sampledAt: Date.now(),
    }
  }

  function forget(video) {
    const entry = tracked.get(video)
    if (!entry) return
    tracked.delete(video)
    send({ type: 'caboose-media.gone', keys: [entry.key] })
  }

  /** Reports a video; `start` is true when it has just started playing. */
  function report(video, start) {
    const media = describe(video)
    const ident = media && (media.videoId || media.src)
    const entry = tracked.get(video)
    // A new source in the same element (the next YouTube video, an ad ending) is new media.
    if (entry && (!media || entry.ident !== ident)) forget(video)
    if (!media) return
    if (!tracked.has(video)) {
      if (!start) return
      tracked.set(video, { key: `${nonce}-${++counter}`, ident })
    }
    send({ type: 'caboose-media.report', key: tracked.get(video).key, start, media })
    schedule()
  }

  function schedule() {
    const playing = [...tracked.keys()].some(video => !video.paused)
    if (playing && !heartbeat) heartbeat = setInterval(beat, HEARTBEAT_MS)
    if (!playing && heartbeat) { clearInterval(heartbeat); heartbeat = undefined }
  }

  function beat() {
    for (const video of [...tracked.keys()]) {
      if (!video.isConnected) forget(video)
      else if (!video.paused) report(video, false)
    }
    schedule()
  }

  function onMedia(event) {
    const video = event.target
    if (!(video instanceof HTMLVideoElement)) return
    switch (event.type) {
      case 'play': report(video, true); break
      // A video can start being offerable mid-play (a YouTube ad ending, say).
      case 'playing': report(video, !tracked.has(video)); break
      case 'pause': case 'seeked': report(video, false); break
      case 'ended': case 'emptied': forget(video); schedule(); break
    }
  }

  // Media events do not bubble, but capture listeners on the document still see them.
  for (const type of ['play', 'playing', 'pause', 'seeked', 'ended', 'emptied']) {
    document.addEventListener(type, onMedia, true)
  }
  addEventListener('pagehide', () => {
    const keys = [...tracked.values()].map(entry => entry.key)
    tracked.clear()
    schedule()
    if (keys.length) send({ type: 'caboose-media.gone', keys })
  })

  chrome.runtime.onMessage.addListener(message => {
    if (!message || message.type !== 'caboose-media.command') return
    const video = [...tracked].find(([, entry]) => entry.key === message.key)?.[0]
    if (!video) return
    if (message.action === 'pause') { video.pause(); return }
    if (message.action !== 'play') return
    if (typeof message.position === 'number' && Number.isFinite(message.position)) {
      const end = Number.isFinite(video.duration) ? video.duration : Infinity
      video.currentTime = Math.min(Math.max(0, message.position), end)
    }
    video.play().catch(error => console.warn('Caboose could not resume the video:', error))
  })
})()
