import { describe, expect, it } from 'vitest'
import {
  INK_DARK, INK_LIGHT, LETTER_X, RAIL, TIE, WORDMARK_VIEWBOX, appIconSvg, faviconSvg, readmeWordmarkSvg, wordmarkSvg,
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

describe('standalone files parse as XML', () => {
  // An <img> parses SVG strictly. A double hyphen inside a comment is a fatal XML
  // error that shows as a broken image, though browsers forgive it in inline SVG.
  const files = { light: readmeWordmarkSvg('light'), dark: readmeWordmarkSvg('dark'), icon: appIconSvg(), favicon: faviconSvg() }
  for (const [name, svg] of Object.entries(files)) {
    it(`${name}: comments never contain "--"`, () => {
      for (const [, body] of svg.matchAll(/<!--([\s\S]*?)-->/g)) expect(body).not.toContain('--')
    })
  }
})

describe('geometry', () => {
  it('spaces "caboose" by the clear space between letters, wheels for o', () => {
    expect(LETTER_X).toEqual([0, 99, 223, 347, 461, 568, 676])
    // The wheels sit 14 apart, rim to rim: the spacing every other pair is set against.
    expect(LETTER_X[4]! - LETTER_X[3]! - 100).toBe(14)
  })

  it('ends the rail flush with the c and the e, clear of the baseline, inside the view box', () => {
    const [x, , width] = WORDMARK_VIEWBOX
    expect(RAIL.y - 6).toBeGreaterThan(100)
    expect(RAIL.from - 6).toBe(0)
    expect(RAIL.to + 6).toBe(LETTER_X[6]! + 100)
    expect(x).toBeLessThan(RAIL.from - 6)
    expect(x + width).toBeGreaterThan(RAIL.to + 6)
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
    expect(wordmarkSvg({ ink: 'currentColor', motion: 'none' })).not.toContain('@keyframes')
    for (const motion of ['intro', 'idle', 'rolling'] as const) {
      expect(wordmarkSvg({ ink: 'currentColor', motion })).toContain('prefers-reduced-motion')
    }
  })

  it('shows the ties only while the train rolls', () => {
    expect(wordmarkSvg({ ink: '#000', motion: 'none' })).not.toContain('<rect')
    // At rest the track is hidden; the cycle fades it in for the roll and out after.
    for (const motion of ['intro', 'idle'] as const) {
      const svg = wordmarkSvg({ ink: '#000', motion, id: 'w' })
      expect(svg).toContain('#w .track { opacity: 0; }')
      expect(svg).toMatch(/#w \.track \{ animation: cb-ties-cycle 24s linear [\d.]+s infinite; \}/)
    }
    // Busy, the ties are always there, sliding.
    expect(wordmarkSvg({ ink: '#000', motion: 'rolling', id: 'w' })).not.toContain('.track {')
  })

  it('an idle logo rolls now and then without drawing itself in', () => {
    const idle = wordmarkSvg({ ink: '#000', motion: 'idle', id: 'w' })
    expect(idle).toContain('#w .wheel { animation: cb-turn-cycle 24s linear 6s infinite; }')
    expect(idle).not.toContain('cb-draw')
  })

  it('a parked computer shows its hubs unlit', () => {
    expect(wordmarkSvg({ ink: '#000' }).match(/fill="#F5A623"/g)).toHaveLength(2)
    const parked = wordmarkSvg({ ink: '#000', lit: false })
    expect(parked).not.toContain('#F5A623')
    expect(parked.match(/r="10" fill="#000" opacity=".22"/g)).toHaveLength(2)
  })

  it('sizes from height when given, from CSS when not', () => {
    expect(wordmarkSvg({ ink: '#000', height: 45 })).toContain('width="196" height="45"')
    expect(wordmarkSvg({ ink: '#000' })).not.toMatch(/<svg[^>]* height=/)
  })
})
