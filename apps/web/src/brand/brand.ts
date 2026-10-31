/**
 * The Caboose brand, drawn from one set of numbers.
 *
 * "On the rails" (Precision Evolution): an optically engineered wordmark riding above a
 * dual-flange rail with a warm amber data-pulse, whose two o's are machined wheels —
 * outer rim, inner flange ring, recessed 12-o'clock power index, and luminous amber hub
 * each, so at rest they double as power buttons. One of those wheels, alone on navy, is
 * the app icon.
 *
 * Every rendering is built here: the README lockups and app icon in `.github/assets`,
 * the console's favicon, and the console's own logo components. `brand.test.ts` holds
 * the checked-in files to this output, so they cannot drift; regenerate them with
 * `pnpm --filter caboose-web test -u`. The iOS app draws the same geometry natively
 * (`apps/ios/Caboose/Brand/CabooseBrand.swift`); change both together.
 *
 * Units: the wordmark's x-height bowls sit on a 100-unit body, stroked at 18.5
 * with butt caps and optical bowl-to-stem tapers. Baseline sits at y=100, clear of a
 * dual-flange rail centred at y=114 (primary) and y=121 (flange).
 */

export const INK_LIGHT = '#1B2B4A'
export const INK_DARK = '#E8EDF4'
export const AMBER = '#F5A623'
export const AMBER_LIGHT = '#FFD26A'
export const AMBER_DEEP = '#D97706'
/** The app icon: cream steel on a navy field. */
export const ICON_STEEL = '#F1ECE2'
export const ICON_NAVY_TOP = '#22355A'
export const ICON_NAVY_BOTTOM = '#111A2E'

export type Motion = 'intro' | 'idle' | 'rolling' | 'none'

export interface BrandOptions {
  /** Stroke colour; `currentColor` lets the surrounding text colour (and theme) decide. */
  ink: string
  amber?: string
  /**
   * `intro` draws the logo in and rolls three wheel-turns, then rolls again now and then.
   * `idle` is the still logo that rolls three wheel-turns now and then.
   * `rolling` keeps the wheels turning and the ties sliding (busy states).
   * `none` is the still logo. At rest the rail stands alone; the ties show only while the
   * train rolls. All motion stops under `prefers-reduced-motion`.
   */
  motion?: Motion
  /** Unique per document when several logos share a page; it scopes styles and clip ids. */
  id?: string
  /** Rendered height in px. Width follows the aspect ratio. Omit to size with CSS. */
  height?: number
}

const round = (value: number) => Math.round(value * 100) / 100

/** Wheel radius and stroke width. */
export const WHEEL_R = 40.5
export const STROKE_W = 18.5

/** Six ties per wheel revolution (2πr / 6), so one full turn of a wheel lands seamlessly. */
export const TIE = (2 * Math.PI * WHEEL_R) / 6
const ROLL = round(TIE * 6)

const ring = (cx: number) => `<circle class="st" pathLength="1" cx="${cx}" cy="50" r="${WHEEL_R}"/>`
const stroke = (d: string) => `<path class="st" pathLength="1" d="${d}"/>`

/**
 * Optically engineered glyph strokes, origin at the glyph's left edge, x-height 0..100,
 * and the horizontal extent of each glyph's ink, which the spacing below is measured from.
 *
 * - `a` and `b` taper their bowls into their vertical stems so stroke joins never blob.
 * - `s` follows a single continuous cubic-Bézier spine with balanced upper/lower counters.
 * - `e` draws its crossbar and arch in one continuous path to avoid a right-hand overlap blotch.
 */
const GLYPHS = {
  c: {
    ink: [0, 89],
    strokes: [stroke('M81.5 24.5C68 8 36 6 19 23C3 39 3 61 19 77C36 94 68 92 81.5 75.5')],
  },
  a: {
    ink: [0, 100],
    strokes: [
      stroke('M88 28C78 13 62 9 46 9C23 9 8 26 8 50C8 74 23 91 46 91C62 91 78 87 88 72'),
      stroke('M90 3V97'),
    ],
  },
  b: {
    ink: [0, 104],
    strokes: [
      stroke('M12 -36V97'),
      stroke('M14 28C24 13 40 9 56 9C79 9 94 26 94 50C94 74 79 91 56 91C40 91 24 87 14 72'),
    ],
  },
  o: { ink: [0, 100], strokes: [] },
  s: {
    ink: [0, 91],
    strokes: [
      stroke('M78 23C69 11 53 8 39 10C21 12 13 21 15 32C17 44 34 46 51 50C69 54 83 60 82 74C81 86 66 92 46 92C28 92 14 86 9 74'),
    ],
  },
  e: {
    ink: [0, 98],
    strokes: [
      stroke('M13 48H88C89 24 72 9 49 9C25 9 9 27 9 50C9 74 26 91 51 91C69 91 81 84 87 72'),
    ],
  },
} as const

const WORD = ['c', 'a', 'b', 'o', 'o', 's', 'e'] as const

/**
 * The clear space between neighbours' ink, set optically: the o-wheels' 14 is the anchor;
 * the open c sits closer to the a, and the a's stem facing the b's stem gets breathing room.
 */
const GAPS = [13, 24, 18, 14, 12, 13] as const

/** Left edge of each letter of "caboose": [0, 102, 226, 348, 462, 574, 678]. */
export const LETTER_X: readonly number[] = WORD.reduce<number[]>((xs, letter, index) => {
  if (index === 0) return [0]
  const before = GLYPHS[WORD[index - 1]!]
  xs.push(round(xs[index - 1]! + before.ink[1] + GAPS[index - 1]! - GLYPHS[letter].ink[0]))
  return xs
}, [])

/** The word's right edge: where the e's ink ends (776), and where the rail ends with it. */
const WORD_END = LETTER_X[WORD.length - 1]! + GLYPHS.e.ink[1]

/**
 * The primary rail spans the word: its round caps (radius 3.5, width 7) sit at 8..768
 * inside the word's 0..776 span, with a secondary machined flange line at y=121 (44..732).
 */
export const RAIL = { from: 8, to: WORD_END - 8, y: 114, flangeY: 121, flangeFrom: 44, flangeTo: WORD_END - 44 } as const
const TIE_Y = 124
const TRACK = { from: RAIL.from, to: RAIL.to } as const

/**
 * Wordmark view box: x, y, width, height. Holds the rail, lower flange, ties, and b's ascender.
 */
export const WORDMARK_VIEWBOX = [-12, -46, 800, 186] as const

/** Motion timeline (seconds). The iOS port mirrors these. */
export const TIMING = {
  rail: { delay: 0.05, duration: 0.8 },
  letter: (index: number) => round(0.18 + index * 0.06),
  draw: 0.65,
  hubAfter: 0.55,
  pop: 0.5,
  roll: { delay: 0.65, duration: 3.2, turns: 3 },
  /** The ties fade in as the train starts and fade out after it stops. */
  ties: { in: 0.4, out: 0.8 },
  /** An idle logo first rolls this long after it appears, */
  idleDelay: 6,
  /** and every logo at rest rolls again once a cycle. */
  cycle: 24,
} as const

function styles(scope: string, motion: Motion): string {
  const s = `#${scope}`
  const { turns } = TIMING.roll
  const travel = round(ROLL * turns)
  const percent = (seconds: number) => `${round((seconds / TIMING.cycle) * 100)}%`
  // The share of each cycle spent rolling; the rest of it the train is at rest.
  const rolling = percent(TIMING.roll.duration)
  const base = `${s} .wheel, ${s} .pop { transform-box: fill-box; transform-origin: center; }`
  if (motion === 'none') return base
  const common = `
    @keyframes cb-roll { from { transform: translateX(${ROLL}px); } to { transform: translateX(0); } }
    @keyframes cb-turn { from { transform: rotate(-360deg); } to { transform: rotate(0); } }
    @keyframes cb-beam { from { transform: translateX(-240px); } to { transform: translateX(800px); } }
    ${base}
    @media (prefers-reduced-motion: reduce) { ${s} * { animation: none !important; } }`
  if (motion === 'rolling') {
    return `${common}
    ${s} .wheel { animation: cb-turn 1.8s linear infinite; }
    ${s} .ties { animation: cb-roll 1.8s linear infinite; }
    ${s} .beam { animation: cb-beam 1.8s linear infinite; }`
  }
  const { rail, draw, pop, roll, ties, cycle } = TIMING
  const cycles = `
    @keyframes cb-roll-cycle {
      0% { transform: translateX(${travel}px); animation-timing-function: cubic-bezier(.45,0,.2,1); }
      ${rolling}, 100% { transform: translateX(0); }
    }
    @keyframes cb-turn-cycle {
      0% { transform: rotate(-${360 * turns}deg); animation-timing-function: cubic-bezier(.45,0,.2,1); }
      ${rolling}, 100% { transform: rotate(0); }
    }
    @keyframes cb-ties-cycle {
      0%, ${percent(roll.duration + ties.out)}, 100% { opacity: 0; }
      ${percent(ties.in)}, ${rolling} { opacity: 1; }
    }
    @keyframes cb-beam-cycle {
      0% { transform: translateX(-240px); opacity: 0; animation-timing-function: cubic-bezier(.4,0,.2,1); }
      ${percent(ties.in)}, ${percent(roll.duration - ties.in)} { opacity: 1; }
      ${rolling}, 100% { transform: translateX(800px); opacity: 0; }
    }
    ${s} .track { opacity: 0; }
    ${s} .beam { opacity: 0; }`
  // Resting styles are the finished logo, ties hidden; every animation fills backwards
  // or not at all, so a renderer that ignores animation (or a reader with reduced motion)
  // still sees the whole still logo.
  if (motion === 'idle') {
    const first = TIMING.idleDelay
    return `${common}${cycles}
    ${s} .wheel { animation: cb-turn-cycle ${cycle}s linear ${first}s infinite; }
    ${s} .ties { animation: cb-roll-cycle ${cycle}s linear ${first}s infinite; }
    ${s} .track { animation: cb-ties-cycle ${cycle}s linear ${first}s infinite; }
    ${s} .beam { animation: cb-beam-cycle ${cycle}s linear ${first}s infinite; }`
  }
  const ease = 'cubic-bezier(.22,1,.36,1)'
  const rollEase = 'cubic-bezier(.16,1,.3,1)'
  return `${common}${cycles}
    @keyframes cb-draw { from { stroke-dashoffset: 1; } }
    @keyframes cb-fade { from { opacity: 0; } }
    @keyframes cb-pop { from { opacity: 0; transform: scale(.2); } }
    @keyframes cb-roll-in { from { transform: translateX(${travel}px); } }
    @keyframes cb-turn-in { from { transform: rotate(-${360 * turns}deg); } }
    ${s} .st { stroke-dasharray: 1; animation: cb-draw ${draw}s ${ease} var(--d) backwards; }
    ${s} .rail { stroke-dasharray: 1; animation: cb-draw ${rail.duration}s ${ease} ${rail.delay}s backwards; }
    ${s} .flange, ${s} .spoke { animation: cb-fade .35s ease-out var(--d) backwards; }
    ${s} .pop { animation: cb-pop ${pop}s cubic-bezier(.34,1.56,.64,1) var(--d) backwards; }
    ${s} .wheel { animation: cb-turn-in ${roll.duration}s ${rollEase} ${roll.delay}s backwards, cb-turn-cycle ${cycle}s linear ${roll.delay + cycle}s infinite; }
    ${s} .ties { animation: cb-roll-in ${roll.duration}s ${rollEase} ${roll.delay}s backwards, cb-roll-cycle ${cycle}s linear ${roll.delay + cycle}s infinite; }
    ${s} .track { animation: cb-ties-cycle ${cycle}s linear ${roll.delay}s infinite; }
    ${s} .beam { animation: cb-beam-cycle ${cycle}s linear ${roll.delay}s infinite; }`
}

const delay = (seconds: number) => ` style="--d:${round(seconds)}s"`

/**
 * One o-wheel with its left edge at `x`: outer rim, machined inner flange ring,
 * recessed 12-o'clock power spoke, and hub. A lit hub is luminous amber; an unlit
 * one (a parked computer) is the ink, faint.
 */
function wheel(x: number, hub: string, start: number, lit = true): string {
  const fill = lit ? `fill="${hub}"` : `fill="${hub}" opacity=".22"`
  return `<g transform="translate(${x} 0)">` +
    `<g class="wheel"${delay(start)}>${ring(50)}` +
    `<circle class="flange" cx="50" cy="50" r="24" stroke-width="2" stroke-opacity=".22"/>` +
    `<path class="spoke" d="M50 35V14" stroke-width="10" stroke-linecap="round"/></g>` +
    `<circle class="pop"${delay(start + TIMING.hubAfter)} cx="50" cy="50" r="10.5" ${fill} stroke="none"/></g>`
}

/** Precision machined sleepers under the rail, one every TIE, sliding left as the train rolls right. */
function ties(from: number, to: number, ink: string, opacity: number): string {
  let rects = ''
  for (let k = Math.floor(from / TIE); k * TIE < to; k++) {
    rects += `<rect x="${round(k * TIE)}" y="${TIE_Y}" width="10" height="4" rx="1.5"/>`
  }
  return `<g class="ties" fill="${ink}" opacity="${opacity}">${rects}</g>`
}

function open(box: readonly number[], id: string, height: number | undefined, extra = ''): string {
  const size = height === undefined ? '' : ` width="${round((height * box[2]!) / box[3]!)}" height="${height}"`
  return `<svg xmlns="http://www.w3.org/2000/svg" id="${id}" viewBox="${box.join(' ')}"${size} role="img" aria-labelledby="${id}-title"${extra}>` +
    `<title id="${id}-title">Caboose</title>`
}

/** The wordmark: "caboose" on the dual-flange rail, its o's for precision wheels. */
export function wordmarkSvg(options: BrandOptions & { lit?: boolean }): string {
  const { ink, amber = AMBER, motion = 'intro', id = 'caboose', height, lit = true } = options
  const letters = WORD.map((letter, index) => {
    const x = LETTER_X[index]!
    const start = TIMING.letter(index)
    if (letter === 'o') return lit ? wheel(x, amber, start) : wheel(x, ink, start, false)
    return `<g transform="translate(${x} 0)"${delay(start)}>${GLYPHS[letter].strokes.join('')}</g>`
  }).join('')
  // The ties and rail pulse show only while the train rolls, so a still logo has none to hide.
  const beamDefs = lit ?
    `<clipPath id="${id}-rail-clip"><rect x="${RAIL.from}" y="${RAIL.y - 4}" width="${RAIL.to - RAIL.from}" height="8" rx="3.5"/></clipPath>` +
    `<linearGradient id="${id}-beam" x1="0" y1="0" x2="1" y2="0">` +
    `<stop offset="0" stop-color="${amber}" stop-opacity="0"/>` +
    `<stop offset=".5" stop-color="${AMBER_LIGHT}" stop-opacity=".95"/>` +
    `<stop offset="1" stop-color="${amber}" stop-opacity="0"/>` +
    `</linearGradient>` : ''
  const track = motion === 'none' ? '' :
    `<defs><clipPath id="${id}-track"><rect x="${TRACK.from}" y="${RAIL.y - 5}" width="${TRACK.to - TRACK.from}" height="32"/></clipPath>${beamDefs}</defs>` +
    `<g class="track" clip-path="url(#${id}-track)">${ties(TRACK.from - ROLL * TIMING.roll.turns, TRACK.to, ink, 0.36)}</g>`
  const beam = motion === 'none' || !lit ? '' :
    `<g clip-path="url(#${id}-rail-clip)"><rect class="beam" x="0" y="${RAIL.y - 3.5}" width="220" height="7" rx="3.5" fill="url(#${id}-beam)"/></g>`
  return open(WORDMARK_VIEWBOX, id, height) +
    `<style>${styles(id, motion)}</style>` +
    track +
    `<path class="rail" pathLength="1" d="M${RAIL.from} ${RAIL.y}H${RAIL.to}" fill="none" stroke="${ink}" stroke-width="7" stroke-linecap="round"/>` +
    `<path class="rail" pathLength="1" d="M${RAIL.flangeFrom} ${RAIL.flangeY}H${RAIL.flangeTo}" fill="none" stroke="${ink}" stroke-opacity=".2" stroke-width="2" stroke-linecap="round"/>` +
    beam +
    `<g fill="none" stroke="${ink}" stroke-width="${STROKE_W}" stroke-linejoin="round">${letters}</g>` +
    `</svg>`
}

/** One o-wheel, as a mark: outer rim, inner flange ring, recessed spoke and amber hub, outer edge 0..100. Reads as ⏻. */
function powerWheel(steel: string, hub: string): string {
  return `<circle cx="50" cy="50" r="${WHEEL_R}" fill="none" stroke="${steel}" stroke-width="${STROKE_W}"/>` +
    `<circle cx="50" cy="50" r="24" fill="none" stroke="${steel}" stroke-width="2.2" stroke-opacity=".28"/>` +
    `<path d="M50 35V14" stroke="${steel}" stroke-width="10" stroke-linecap="round"/>` +
    `<circle cx="50" cy="50" r="10.5" fill="${hub}"/>`
}

function navyField(id: string): string {
  return `<defs><linearGradient id="${id}-field" x1="0" y1="0" x2="1" y2="1">` +
    `<stop offset="0" stop-color="${ICON_NAVY_TOP}"/><stop offset="1" stop-color="${ICON_NAVY_BOTTOM}"/></linearGradient></defs>`
}

/**
 * The app icon, 1024 square: one precision wheel of the wordmark, large, on a navy field.
 * Reads as a power button, which is what opening Caboose does. Static: iOS icons do
 * not move, and the PNG is rendered from this file.
 */
export function appIconSvg(): string {
  const id = 'caboose-icon'
  return `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1024 1024" width="1024" height="1024">` +
    navyField(id) +
    `<rect width="1024" height="1024" fill="url(#${id}-field)"/>` +
    `<g transform="translate(192 192) scale(6.4)">${powerWheel(ICON_STEEL, AMBER)}</g>` +
    `</svg>`
}

/** Browser tab icon: the app icon as a rounded tile, legible on light and dark tab bars. */
export function faviconSvg(): string {
  const id = 'caboose-tab'
  return `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 64 64">` +
    navyField(id) +
    `<rect width="64" height="64" rx="14" fill="url(#${id}-field)"/>` +
    `<g transform="translate(10 10) scale(.44)">${powerWheel(ICON_STEEL, AMBER)}</g>` +
    `</svg>`
}

/**
 * README lockup, light or dark (GitHub picks with `<picture>`), annotated for readers of the file.
 * The note is an XML comment, so it must never contain a double hyphen: GitHub loads the file
 * as an image, which parses strictly, and one `--` leaves the README with a broken image.
 */
export function readmeWordmarkSvg(scheme: 'light' | 'dark'): string {
  const note = `<!-- Caboose wordmark (${scheme}). Generated by apps/web/src/brand/brand.ts; do not edit by hand —\n` +
    `     change brand.ts and run \`pnpm -F caboose-web test -u\`. The dual-flange rail draws, "caboose"\n` +
    `     writes itself in, the amber hubs pop, and the train rolls three wheel-turns over machined\n` +
    `     sleepers with an amber rail pulse, then again every ${TIMING.cycle} s. Resting styles are the\n` +
    `     finished logo, so still renderers show it complete. -->\n`
  return note + wordmarkSvg({ ink: scheme === 'light' ? INK_LIGHT : INK_DARK, motion: 'intro', height: 120 }) + '\n'
}
