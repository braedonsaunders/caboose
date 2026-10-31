// node --test guest/scroll-reporter/chromium/core.test.mjs
import { test } from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { createRequire } from 'node:module'

const C = createRequire(import.meta.url)('./core.js')
const vector = JSON.parse(readFileSync(new URL('../../display/vectors/scroll-tag/scroll-tag.json', import.meta.url)))

test('tag blocks match the golden vector', () => {
  for (const { value, blocks } of vector.tags) {
    assert.equal(C.tagBlocks(value).map(b => (b ? '1' : '0')).join(''), blocks)
  }
})

test('the tag goes at the line the bind names, a whole number of CSS pixels per block', () => {
  const bind = { active: true, overscan: [0, 600], tag_top: 2204, block: 32 }
  assert.deepEqual(C.tagRect(bind, 1, 2976), { css: [0, 2204, 1024, 32], device: [0, 2204, 1024, 32] })
  // At 2.625 a block is 13 CSS pixels, 34.125 device pixels: never smaller than asked.
  assert.deepEqual(C.tagRect(bind, 2.625, 1134).css, [0, 840, 416, 13])
  // No room below the line, or no overscan at all.
  assert.equal(C.tagRect(bind, 1, 2220), null)
  assert.equal(C.tagRect({ ...bind, overscan: [0, 0] }, 1, 2976), null)
  assert.equal(C.tagRect({ ...bind, active: false }, 1, 2976), null)
})

test('a sticky element counts as fixed only while stuck', () => {
  const clip = { left: 0, top: 0, right: 900, bottom: 800 }
  const insets = { top: 0, bottom: NaN, left: NaN, right: NaN }
  assert.ok(C.stuck({ left: 0, top: 0, right: 900, bottom: 48 }, insets, clip))
  assert.ok(!C.stuck({ left: 0, top: 300, right: 900, bottom: 348 }, insets, clip))
})

test('a report changes with anything but its frame number', () => {
  const a = { frame: 1, applied: 3, scrollers: [{ offset: [0, 10] }] }
  assert.ok(!C.changed(a, { ...a, frame: 2 }))
  assert.ok(C.changed(a, { ...a, applied: 4 }))
  assert.ok(C.changed(null, a))
})

test('a layout shift moves two sample elements alike; rounding and one animation do not', () => {
  assert.ok(C.coherentShift([0, 50, 50.4], 1))
  assert.ok(C.coherentShift([-120, -120, -120], 1))
  assert.ok(!C.coherentShift([0.6, -0.4, 0.8], 1))
  assert.ok(!C.coherentShift([0, 30, 0], 1))
  assert.ok(!C.coherentShift([0, 30, -60], 1))
})
