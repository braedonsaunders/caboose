// Collects what every tab and frame reports, offers the most recent video to the native
// host com.caboose.media (which writes it where caboose-host reads it), and relays the
// host's pause / play commands back to the frame that owns the video.
importScripts('media-kind.js')
const { ID_PATTERN, isHttp, cleanTitle, duration } = globalThis.CabooseMedia
const HOST = 'com.caboose.media'
const KEY = /^[a-z0-9]{1,12}-\d{1,9}$/
// Playing videos report every 5 s; a muted one in a hidden tab can be throttled to once a
// minute. Twice that with no report means its renderer is gone.
const STALE_MS = 150_000
const SWEEP = 'caboose-media-sweep'

/** id → { id, tabId, frameId, key, startedAt, page, tabTitle, media } */
const entries = new Map()
let port
let published
let reconnect

// Session storage outlives this worker being stopped and restarted, not the browser.
const restored = chrome.storage.session.get('entries').then(saved => {
  for (const entry of saved.entries ?? []) entries.set(entry.id, entry)
}, () => {})

function save() {
  return chrome.storage.session.set({ entries: [...entries.values()] }).catch(() => {})
}

function connect() {
  clearTimeout(reconnect)
  reconnect = undefined
  if (port) return
  try {
    port = chrome.runtime.connectNative(HOST)
  } catch (error) {
    console.warn('Caboose media host unavailable:', error)
    retry()
    return
  }
  published = undefined
  port.onMessage.addListener(message => { void restored.then(() => command(message)) })
  port.onDisconnect.addListener(() => {
    console.warn('Caboose media host disconnected:', chrome.runtime.lastError?.message ?? 'closed')
    port = undefined
    published = undefined
    retry()
  })
  publish()
}

function retry() {
  if (!reconnect) reconnect = setTimeout(connect, 10_000)
}

/** The video the phone is offered: the latest to start among those playing, else the latest. */
function current() {
  let best
  for (const entry of entries.values()) {
    const rank = [entry.media.paused ? 0 : 1, entry.startedAt]
    if (!best || rank[0] > best.rank[0] || (rank[0] === best.rank[0] && rank[1] > best.rank[1])) best = { entry, rank }
  }
  return best?.entry
}

function toMedia(entry) {
  const { media } = entry
  return {
    id: entry.id,
    page: entry.page,
    title: media.title || cleanTitle(entry.tabTitle),
    ...(media.src ? { src: media.src } : {}),
    kind: media.kind,
    position: media.position,
    duration: media.duration,
    paused: media.paused,
    updatedAt: media.sampledAt,
  }
}

function prune(now = Date.now()) {
  for (const [id, entry] of entries) {
    if (!entry.media.paused && now - entry.media.sampledAt > STALE_MS) entries.delete(id)
  }
}

function publish() {
  prune()
  const entry = current()
  const media = entry ? toMedia(entry) : null
  const text = JSON.stringify(media)
  if (!port || text === published) return
  try {
    port.postMessage({ type: 'media', media })
    published = text
  } catch (error) {
    console.warn('Caboose media host write failed:', error)
  }
}

/** Only what the content script is expected to send survives; anything else is dropped. */
function sanitize(media) {
  if (!media || typeof media !== 'object') return undefined
  const { kind, src, position, paused, sampledAt, frameUrl } = media
  if (!['page', 'hls', 'video'].includes(kind) || typeof paused !== 'boolean') return undefined
  if (kind === 'page' ? src !== undefined : !isHttp(src) || src.length > 4096) return undefined
  if (typeof position !== 'number' || !Number.isFinite(position) || position < 0) return undefined
  if (typeof sampledAt !== 'number' || !Number.isFinite(sampledAt)) return undefined
  return {
    kind, ...(src ? { src } : {}),
    title: cleanTitle(media.title), frameUrl: isHttp(frameUrl) ? frameUrl : '',
    position, duration: duration(media.duration), paused, sampledAt,
  }
}

function handle(message, sender) {
  const tabId = sender.tab.id
  const frameId = sender.frameId ?? 0
  if (message.type === 'caboose-media.gone' && Array.isArray(message.keys)) {
    for (const key of message.keys) entries.delete(`${tabId}.${frameId}.${key}`)
  } else if (message.type === 'caboose-media.report' && KEY.test(message.key)) {
    const id = `${tabId}.${frameId}.${message.key}`
    const media = sanitize(message.media)
    if (!ID_PATTERN.test(id) || !media) return
    const previous = entries.get(id)
    const page = isHttp(sender.tab.url) && sender.tab.url.length <= 4096 ? sender.tab.url : media.frameUrl
    entries.set(id, {
      id, tabId, frameId, key: message.key,
      startedAt: message.start === true || !previous ? Date.now() : previous.startedAt,
      page, tabTitle: sender.tab.title ?? '', media,
    })
  } else return
  void save()
  publish()
}

function command(message) {
  if (!message || message.type !== 'command' || typeof message.id !== 'string') return
  const entry = entries.get(message.id)
  if (!entry || (message.action !== 'pause' && message.action !== 'play')) return
  const relay = { type: 'caboose-media.command', key: entry.key, action: message.action }
  if (typeof message.position === 'number' && Number.isFinite(message.position)) relay.position = message.position
  chrome.tabs.sendMessage(entry.tabId, relay, { frameId: entry.frameId }).catch(error => {
    console.warn('Caboose media command was not delivered:', error)
  })
}

async function sweep() {
  await restored
  const tabs = new Set((await chrome.tabs.query({})).map(tab => tab.id))
  for (const [id, entry] of entries) if (!tabs.has(entry.tabId)) entries.delete(id)
  await save()
  publish()
}

chrome.runtime.onMessage.addListener((message, sender) => {
  if (sender.id !== chrome.runtime.id || !sender.tab?.id || !message || typeof message !== 'object') return
  void restored.then(() => handle(message, sender))
})
chrome.tabs.onRemoved.addListener(tabId => {
  void restored.then(() => {
    for (const [id, entry] of entries) if (entry.tabId === tabId) entries.delete(id)
    void save()
    publish()
  })
})
chrome.alarms.onAlarm.addListener(alarm => { if (alarm.name === SWEEP) void sweep() })
// Starting with the browser clears what a previous session left in the state file.
chrome.runtime.onStartup.addListener(() => { void sweep() })
chrome.runtime.onInstalled.addListener(() => { void sweep() })
void chrome.alarms.get(SWEEP).then(alarm => { if (!alarm) return chrome.alarms.create(SWEEP, { periodInMinutes: 1 }) })
void restored.then(connect)
