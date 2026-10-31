// The scroll reporter's pure logic, shared by content.js and the unit tests: the frame tag
// (docs/display.md, "Frame tag"), the shape of a report and when one has changed.
;(() => {
  const BLOCKS = 32
  const SYNC = [true, false, true, false]

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

  /**
   * Where the tag goes, viewport device pixels [x, y, w, h], or null when the bind leaves
   * no room for it: the first overscan line, one block tall, within the overscan.
   */
  function tagRect(bind, dpr) {
    if (!bind || !bind.active) return null
    const side = blockCss(bind.block, dpr)
    const top = Math.round(bind.tag_top / dpr)
    if (!(bind.overscan[1] >= side * dpr) || !(top >= 0)) return null
    return { css: [0, top, BLOCKS * side, side], device: [0, top * dpr, BLOCKS * side * dpr, side * dpr] }
  }

  const round = v => Math.round(v * 100) / 100

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

  const api = { BLOCKS, tagBlocks, tagValue, blockCss, tagRect, deviceRect, stuck, intersects, changed, documentY }
  globalThis.CabooseScrollCore = api
  if (typeof module === 'object' && module.exports) module.exports = api
})()
