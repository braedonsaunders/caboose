// Runs in every top-level page. Per frame, after layout, it reads where the page is
// scrolled (the root scroller and the largest inner one), their ranges and the fixed and
// stuck sticky elements over them, and reports it through the service worker to
// caboose-display. While a client places pictures by these reports it also draws the frame
// tag in the window's bottom overscan, in the same frame, so each picture names its report,
// and it applies the client's scroll.target deltas exactly (docs/display.md, "Scroll reports").
;(() => {
  if (globalThis.cabooseScrollReporter) return
  globalThis.cabooseScrollReporter = true
  const C = globalThis.CabooseScrollCore

  let port = null
  let bind = null
  let frame = 0
  let applied = 0
  let epoch = 0
  let lastSent = null
  let lastSentAt = 0
  const targets = []

  // ---- The reporter's own element: a probe that makes ResizeObserver run after layout,
  // and the tag. A closed shadow root keeps the page's styles and scripts away from it.
  const host = document.createElement('caboose-scroll-reporter')
  host.setAttribute('style', 'all: initial !important; position: fixed !important; left: 0 !important; top: 0 !important; width: 0 !important; height: 0 !important; z-index: 2147483647 !important; pointer-events: none !important;')
  const shadow = host.attachShadow({ mode: 'closed' })
  const probe = document.createElement('div')
  probe.setAttribute('style', 'position: absolute; left: 0; top: 0; height: 1px; width: 0; visibility: hidden;')
  const canvas = document.createElement('canvas')
  canvas.width = C.BLOCKS
  canvas.height = 1
  canvas.setAttribute('style', 'position: absolute; left: 0; display: none; image-rendering: pixelated;')
  shadow.append(probe, canvas)
  const paint = canvas.getContext('2d')
  const pixels = paint.createImageData(C.BLOCKS, 1)

  function attach() {
    if (!host.isConnected && document.documentElement) document.documentElement.append(host)
  }

  function drawTag(tag, value) {
    if (!tag) {
      canvas.style.display = 'none'
      return
    }
    const blocks = C.tagBlocks(value)
    for (let i = 0; i < C.BLOCKS; i++) {
      const v = blocks[i] ? 255 : 0
      pixels.data.set([v, v, v, 255], i * 4)
    }
    paint.putImageData(pixels, 0, 0)
    const [x, y, w, h] = tag.css
    Object.assign(canvas.style, { display: 'block', left: `${x}px`, top: `${y}px`, width: `${w}px`, height: `${h}px` })
  }

  // ---- Scrollers. The root is 0; inner ones get ids as they are found.
  const ids = new WeakMap()
  const byId = new Map()
  let nextId = 1
  const seen = new Set()
  let inner = null
  let lastInnerScan = 0

  function idOf(el) {
    let id = ids.get(el)
    if (!id) {
      id = nextId++
      ids.set(el, id)
      byId.set(id, el)
    }
    return id
  }

  function scrollable(el) {
    if (!(el instanceof Element) || el === document.documentElement || el === document.body) return false
    if (el.scrollHeight <= el.clientHeight + 1 && el.scrollWidth <= el.clientWidth + 1) return false
    const s = getComputedStyle(el)
    return /(auto|scroll|overlay)/.test(s.overflowY + s.overflowX)
  }

  function visibleArea(el) {
    const r = el.getBoundingClientRect()
    const w = Math.min(r.right, innerWidth) - Math.max(r.left, 0)
    const h = Math.min(r.bottom, innerHeight) - Math.max(r.top, 0)
    return w > 0 && h > 0 ? w * h : 0
  }

  // The largest inner scroller: among those that scrolled, and the ancestors of the
  // page's centre, which is where app-like pages put their main scroller.
  function findInner(now) {
    if (now - lastInnerScan < 1000 && (!inner || inner.isConnected)) return inner
    lastInnerScan = now
    let el = document.elementFromPoint(innerWidth / 2, innerHeight / 2)
    for (; el && el !== document.documentElement; el = el.parentElement) {
      if (scrollable(el)) seen.add(el)
    }
    let best = null
    let bestArea = innerWidth * innerHeight * 0.1
    for (const s of seen) {
      if (!s.isConnected || !scrollable(s)) {
        seen.delete(s)
        const id = ids.get(s)
        if (id) byId.delete(id)
        continue
      }
      const area = visibleArea(s)
      if (area > bestArea) {
        best = s
        bestArea = area
      }
    }
    inner = best
    return inner
  }

  // ---- Fixed and sticky elements, found by a walk of the page a few hundred elements per
  // frame, so a large page never costs one long frame.
  let fixed = []
  let walking = null
  let walkFound = []
  let lastWalk = -Infinity
  const PER_FRAME = 600

  function walkStep(now) {
    if (!walking) {
      if (now - lastWalk < 1000 || !document.body) return
      walking = document.createTreeWalker(document.body, NodeFilter.SHOW_ELEMENT)
      walkFound = []
    }
    for (let i = 0; i < PER_FRAME; i++) {
      const el = walking.nextNode()
      if (!el) {
        fixed = walkFound
        walking = null
        lastWalk = now
        return
      }
      const s = getComputedStyle(el)
      if (s.position === 'fixed' || s.position === 'sticky') {
        const inset = v => (v === 'auto' ? NaN : parseFloat(v))
        walkFound.push({
          el,
          sticky: s.position === 'sticky',
          insets: { top: inset(s.top), bottom: inset(s.bottom), left: inset(s.left), right: inset(s.right) },
        })
      }
    }
  }

  // ---- Layout shifts: a few elements' positions in the document. Content that moves in
  // document coordinates (an image loading above, scroll anchoring) starts a new epoch.
  let probes = []

  function pickProbes(scrollerEl, clip, scrollTop) {
    probes = []
    for (const f of [0.2, 0.5, 0.8]) {
      let el = document.elementFromPoint(clip.left + clip.width / 2, clip.top + clip.height * f)
      while (el && el !== document.documentElement && el.getBoundingClientRect().height < 24) el = el.parentElement
      if (!el || el === document.documentElement || el === document.body || el === host) continue
      if (scrollerEl && !scrollerEl.contains(el)) continue
      const p = getComputedStyle(el).position
      if (p === 'fixed' || p === 'sticky') continue
      probes.push({ el, y: C.documentY(el.getBoundingClientRect(), clip.top, scrollTop) })
    }
  }

  function shifted(scrollerEl, clip, scrollTop, dpr) {
    const moves = []
    let lost = probes.length === 0
    for (const p of probes) {
      if (!p.el.isConnected) {
        lost = true
        continue
      }
      const r = p.el.getBoundingClientRect()
      moves.push(C.documentY(r, clip.top, scrollTop) - p.y)
      if (r.bottom < clip.top || r.top > clip.bottom) lost = true
    }
    const moved = C.coherentShift(moves, 1.5 / dpr)
    if (moved || lost) pickProbes(scrollerEl, clip, scrollTop)
    return moved
  }

  // ---- One frame.
  function entry(id, rect, offset, range, dpr) {
    return {
      id,
      rect: C.deviceRect(rect, dpr),
      offset: [offset[0] * dpr, offset[1] * dpr],
      range: [Math.max(0, range[0]) * dpr, Math.max(0, range[1]) * dpr],
      fixed: [],
    }
  }

  function measure() {
    const now = performance.now()
    const dpr = devicePixelRatio || 1
    const root = document.scrollingElement || document.documentElement
    if (!root) return
    const rootClip = { left: 0, top: 0, width: root.clientWidth, height: root.clientHeight, right: root.clientWidth, bottom: root.clientHeight }
    const scrollers = [
      entry(0, rootClip, [scrollX, scrollY], [root.scrollWidth - root.clientWidth, root.scrollHeight - root.clientHeight], dpr),
    ]
    const clips = [rootClip]
    const el = findInner(now)
    if (el) {
      const r = el.getBoundingClientRect()
      const clip = { left: r.left + el.clientLeft, top: r.top + el.clientTop, width: el.clientWidth, height: el.clientHeight }
      clip.right = clip.left + clip.width
      clip.bottom = clip.top + clip.height
      const e = entry(idOf(el), clip, [el.scrollLeft, el.scrollTop], [el.scrollWidth - el.clientWidth, el.scrollHeight - el.clientHeight], dpr)
      // The primary scroller first: the root unless only the inner one scrolls.
      if (scrollers[0].range[1] <= 0 && scrollers[0].range[0] <= 0) {
        scrollers.unshift(e)
        clips.unshift(clip)
      } else {
        scrollers.push(e)
        clips.push(clip)
      }
    }
    walkStep(now)
    for (const f of fixed) {
      if (!f.el.isConnected) continue
      const r = f.el.getBoundingClientRect()
      if (r.width <= 0 || r.height <= 0) continue
      clips.forEach((clip, i) => {
        if (!C.intersects(r, clip)) return
        if (f.sticky && !C.stuck(r, f.insets, clip)) return
        if (scrollers[i].fixed.length < 32) scrollers[i].fixed.push(C.deviceRect(r, dpr))
      })
    }
    const primary = scrollers[0].id === 0 ? null : el
    if (shifted(primary, clips[0], primary ? primary.scrollTop : scrollY, dpr)) epoch++
    const tag = C.tagRect(bind, dpr)
    if (tag) scrollers[0].fixed.push(tag.device)
    const report = {
      type: 'report',
      title: document.title || '',
      outer: [outerWidth * dpr, outerHeight * dpr],
      viewport: [innerWidth * dpr, innerHeight * dpr],
      frame,
      applied,
      epoch,
      tag: tag ? tag.device : null,
      scrollers,
    }
    // Without a client placing pictures, a report only binds the window: a few a second.
    const live = bind && bind.active
    if (!C.changed(lastSent, report)) return
    if (!live && now - lastSentAt < 500) {
      setTimeout(schedule, 500 - (now - lastSentAt))
      return
    }
    frame = (frame + 1) & 0xffff
    report.frame = frame
    drawTag(tag, C.tagValue(bind ? bind.reporter : 0, frame))
    lastSent = report
    lastSentAt = now
    post(report)
  }

  const observer = new ResizeObserver(() => {
    if (measuring) {
      measuring = false
      measure()
    }
  })
  observer.observe(probe)
  let measuring = false
  let scheduled = false
  let toggle = false

  // A frame: apply the client's scrolling, then measure once layout is done (the probe's
  // size change makes ResizeObserver run after layout, before paint).
  function onFrame() {
    scheduled = false
    if (document.visibilityState !== 'visible') return
    attach()
    const dpr = devicePixelRatio || 1
    for (const t of targets.splice(0)) {
      const el = t.scroller === 0 ? null : byId.get(t.scroller)
      const by = { left: t.delta[0] / dpr, top: t.delta[1] / dpr, behavior: 'instant' }
      if (t.scroller === 0) scrollBy(by)
      else if (el && el.isConnected) el.scrollBy(by)
      applied = Math.max(applied, t.seq)
    }
    toggle = !toggle
    probe.style.width = toggle ? '1px' : '0px'
    measuring = true
    if (bind && bind.active) schedule()
  }

  function schedule() {
    if (scheduled) return
    scheduled = true
    requestAnimationFrame(onFrame)
  }

  // ---- The service worker.
  function post(message) {
    try {
      port?.postMessage(message)
    } catch {
      port = null
    }
  }

  function connect() {
    try {
      port = chrome.runtime.connect({ name: 'scroll' })
    } catch {
      return
    }
    port.onMessage.addListener(message => {
      if (message.type === 'bind') bind = message
      else if (message.type === 'unbind') bind = null
      else if (message.type === 'base') frame = message.frame & 0xffff
      else if (message.type === 'target' && Array.isArray(message.delta)) targets.push(message)
      lastSent = null
      schedule()
    })
    port.onDisconnect.addListener(() => {
      port = null
      bind = null
      drawTag(null)
      setTimeout(connect, 2000)
    })
    post({ type: 'visible' })
  }

  connect()
  addEventListener('scroll', schedule, { capture: true, passive: true })
  document.addEventListener('scroll', event => {
    if (event.target instanceof Element && scrollable(event.target)) seen.add(event.target)
  }, { capture: true, passive: true })
  addEventListener('resize', schedule, { passive: true })
  addEventListener('load', schedule, { once: true })
  document.addEventListener('visibilitychange', () => {
    if (document.visibilityState === 'visible') {
      post({ type: 'visible' })
      lastSent = null
      schedule()
    }
  })
  schedule()
})()
