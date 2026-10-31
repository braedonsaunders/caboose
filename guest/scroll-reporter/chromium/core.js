// The scroll reporter's pure logic, shared by content.js and the unit tests: the frame tag
// (docs/display.md, "Frame tag"), the shape of a report and when one has changed.
;(() => {
  const BLOCKS = 32
  const SYNC = [true, false, true, false]

  const round = v => Math.round(v * 100) / 100

  /** The 32 blocks of a 24-bit tag value, true for white. */
  function tagBlocks(value) {
    value &= 0xffffff
    const blocks = SYNC.slice()
    for (let i = 23; i >= 0; i--) blocks.push(((value >> i) & 1) === 1)
    let check = 0
    for (let i = 0; i < 6; i++) check ^= (value >> (4 * i)) & 0xf
    for (let i = 3; i >= 0; i--) blocks.push(((check >> i) & 1) === 1)
    return blocks
  }

  /** The tag value a reporter's frame number makes. */
  function tagValue(reporter, frame) {
    return ((reporter & 0xff) << 16) | (frame & 0xffff)
  }

  /** The block side in CSS pixels that is at least `device` device pixels. */
  function blockCss(device, dpr) {
    return Math.max(1, Math.ceil(device / dpr - 1e-6))
  }

  /** No pinch zoom: the visual viewport is the layout viewport. */
  const UNZOOMED = { scale: 1, x: 0, y: 0 }

  /**
   * A layout-viewport CSS rect (DOMRect-like) as the window shows it, device pixels: through
   * the visual viewport `view` (its scale and offset), which a pinch zoom magnifies.
   */
  function viewRect(r, view, dpr) {
    const k = view.scale * dpr
    return [round((r.left - view.x) * k), round((r.top - view.y) * k), round(r.width * k), round(r.height * k)]
  }

  /**
   * Where the tag goes, or null when the bind leaves no room for it: at the line the bind
   * names, one block tall, in the overscan and inside a viewport `height` CSS pixels tall.
   * `css` is where to draw it in the layout viewport, so that under a pinch zoom `view` it
   * still lands on those window pixels; `device` is that rect in viewport device pixels.
   */
  function tagRect(bind, dpr, height, view = UNZOOMED) {
    if (!bind || !bind.active || !(bind.overscan[1] > 0)) return null
    const k = dpr * view.scale
    const side = blockCss(bind.block, k)
    const top = Math.round(bind.tag_top / k)
    if (!(top >= 0) || !(top + side <= height / view.scale)) return null
    const css = { left: view.x, top: view.y + top, width: BLOCKS * side, height: side }
    return { css: [css.left, css.top, css.width, css.height], device: viewRect(css, view, dpr) }
  }


  /** A CSS rect (DOMRect-like) in device pixels, rounded to hundredths. */
  function deviceRect(r, dpr) {
    return [round(r.left * dpr), round(r.top * dpr), round(r.width * dpr), round(r.height * dpr)]
  }

  /** Whether a sticky element is stuck: at its inset from the scroller's edge. */
  function stuck(rect, insets, clip) {
    const near = (a, b) => Math.abs(a - b) < 1
    return (Number.isFinite(insets.top) && near(rect.top, clip.top + insets.top))
      || (Number.isFinite(insets.bottom) && near(rect.bottom, clip.bottom - insets.bottom))
      || (Number.isFinite(insets.left) && near(rect.left, clip.left + insets.left))
      || (Number.isFinite(insets.right) && near(rect.right, clip.right - insets.right))
  }

  /** Whether two rects (left/top/right/bottom) overlap. */
  function intersects(a, b) {
    return a.left < b.right && b.left < a.right && a.top < b.bottom && b.top < a.bottom
  }

  /**
   * Whether a report differs from the last one sent in anything a picture would show:
   * everything but the frame number.
   */
  function changed(last, next) {
    if (!last) return true
    const strip = r => JSON.stringify({ ...r, frame: 0 })
    return strip(last) !== strip(next)
  }

  /**
   * The document position of an element along y, to tell a layout shift from scrolling:
   * its top relative to the scroller's content.
   */
  function documentY(rect, clipTop, scrollTop) {
    return rect.top - clipTop + scrollTop
  }

  /**
   * Whether sample elements' document positions moved by a layout shift: at least two by
   * the same amount beyond `threshold` (CSS pixels). One element alone (an animation) or
   * rounding of a fractional scroll offset is not a shift.
   */
  function coherentShift(moves, threshold) {
    const big = moves.filter(m => Math.abs(m) > threshold)
    for (let i = 0; i < big.length; i++) {
      for (let j = i + 1; j < big.length; j++) {
        if (Math.abs(big[i] - big[j]) <= threshold) return true
      }
    }
    return false
  }

  /** The scales Chromium's pinch zoom takes on a desktop. */
  const ZOOM_RANGE = [1, 4]

  const api = { BLOCKS, ZOOM_RANGE, UNZOOMED, tagBlocks, tagValue, blockCss, tagRect, viewRect, deviceRect, stuck, intersects, changed, documentY, coherentShift }
  globalThis.CabooseScrollCore = api
  if (typeof module === 'object' && module.exports) module.exports = api
})()
