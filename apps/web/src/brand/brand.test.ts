import { describe, expect, it } from 'vitest'
import {
  INK_DARK, INK_LIGHT, LETTER_X, TIE, appIconSvg, carSvg, faviconSvg, readmeWordmarkSvg, wordmarkSvg,
} from './brand.js'

// The checked-in brand files are this module's output. `vitest -u` rewrites them.
describe('generated brand files', () => {
  it('README wordmark, light and dark', async () => {
    await expect(readmeWordmarkSvg('light')).toMatchFileSnapshot('../../../../.github/assets/caboose-logo.svg')
    await expect(readmeWordmarkSvg('dark')).toMatchFileSnapshot('../../../../.github/assets/caboose-logo-dark.svg')
  })

  it('app icon (the iOS PNG is rendered from this file)', async () => {
    await expect(appIconSvg() + '\n').toMatchFileSnapshot('../../../../.github/assets/caboose-app-icon.svg')
  })

  it('console favicon', async () => {
    await expect(faviconSvg() + '\n').toMatchFileSnapshot('../../public/favicon.svg')
  })
})

describe('geometry', () => {
  it('sets "caboose" on the advance widths, wheels for o', () => {
    expect(LETTER_X).toEqual([0, 108, 222, 346, 460, 574, 680])
  })

  it('rolls exactly one wheel revolution across a whole number of ties', () => {
    const circumference = 2 * Math.PI * 40
    expect(circumference / TIE).toBeCloseTo(6, 10)
  })

  it('uses the scheme ink for every stroke', () => {
    expect(readmeWordmarkSvg('light')).toContain(`stroke="${INK_LIGHT}"`)
    expect(readmeWordmarkSvg('light')).not.toContain(INK_DARK)
    expect(readmeWordmarkSvg('dark')).toContain(`stroke="${INK_DARK}"`)
  })
})

describe('rendering', () => {
  it('scopes styles and clip paths to the id so several logos can share a page', () => {
    const one = wordmarkSvg({ ink: 'currentColor', id: 'one' })
    const two = wordmarkSvg({ ink: 'currentColor', id: 'two' })
    expect(one).toContain('url(#one-track)')
    expect(two).toContain('url(#two-track)')
    expect(two).not.toContain('#one')
    expect(one).toMatch(/#one \.st \{/)
  })

  it('still logos carry no animation, and every animated one honours reduced motion', () => {
    expect(carSvg({ ink: 'currentColor', motion: 'none' })).not.toContain('@keyframes')
    for (const motion of ['intro', 'rolling'] as const) {
      expect(wordmarkSvg({ ink: 'currentColor', motion })).toContain('prefers-reduced-motion')
      expect(carSvg({ ink: 'currentColor', motion })).toContain('prefers-reduced-motion')
    }
  })

  it('a parked car keeps its windows dark', () => {
    expect(carSvg({ ink: '#000', lights: true })).toContain('<g fill="#F5A623">')
    expect(carSvg({ ink: '#000', lights: false })).toContain('<g fill="#000" opacity=".22">')
  })

  it('sizes from height when given, from CSS when not', () => {
    expect(carSvg({ ink: '#000', height: 34 })).toContain('width="40.6" height="34"')
    expect(carSvg({ ink: '#000' })).not.toMatch(/<svg[^>]* height=/)
  })
})
