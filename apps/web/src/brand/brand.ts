/**
 * The Caboose brand, drawn from one set of numbers.
 *
 * "On the rails": a monoline wordmark standing on a rail whose two o's are wheels —
 * a spoke and an amber hub each, so at rest they double as power buttons. One of
 * those wheels, alone on navy, is the app icon.
 *
 * Every rendering is built here: the README lockups and app icon in `.github/assets`,
 * the console's favicon, and the console's own logo components. `brand.test.ts` holds
 * the checked-in files to this output, so they cannot drift; regenerate them with
 * `pnpm --filter caboose-web test -u`. The iOS app draws the same geometry natively
 * (`apps/ios/Caboose/Brand/CabooseBrand.swift`); change both together.
 *
 * Units: the wordmark's x-height circles are r40 on a 100-unit body, stroked at 20
 * with butt caps. Baseline sits at y=100, on top of a 12-unit rail centred at y=106.
 */

export const INK_LIGHT = '#1B2B4A'
export const INK_DARK = '#E8EDF4'
export const AMBER = '#F5A623'
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

/** Six ties per wheel revolution (2πr / 6), so one full turn of a wheel lands seamlessly. */
export const TIE = (2 * Math.PI * 40) / 6
const ROLL = round(TIE * 6)

const ring = (cx: number) => `<circle class="st" pathLength="1" cx="${cx}" cy="50" r="40"/>`
const stroke = (d: string) => `<path class="st" pathLength="1" d="${d}"/>`

/**
 * Glyph strokes, origin at the glyph's left edge, x-height 0..100, and the horizontal
 * extent of each glyph's ink, which the spacing below is measured from.
 */
const GLYPHS = {
  c: { ink: [0, 87], strokes: [stroke('M79.7 23.2A40 40 0 1 0 79.7 76.8')] },
  a: { ink: [0, 100], strokes: [ring(50), stroke('M90 0L90 100')] },
  b: { ink: [0, 110], strokes: [stroke('M10 -38L10 100'), ring(60)] },
  o: { ink: [0, 100], strokes: [] },
  // Two stacked elliptical bowls, the lower a little fuller, meeting on a level spine.
  // The terminals end near level, so their butt cuts sit almost flat and the s stands upright.
  s: { ink: [9, 93], strokes: [stroke('M80.08 24.4A31 19 0 1 0 50 48A33 21 0 1 1 17.98 74.08')] },
  e: { ink: [0, 100], strokes: [stroke('M90 50A40 40 0 1 0 82.77 72.94'), stroke('M10 50L100 50')] },
} as const

const WORD = ['c', 'a', 'b', 'o', 'o', 's', 'e'] as const

/**
 * The clear space between neighbours' ink, set by eye rather than by box: the o-wheels'
 * 14 is the anchor; the open c needs less, and the a's stem facing the b's stem needs more.
 */
const GAPS = [12, 24, 14, 14, 16, 15] as const

/** Left edge of each letter of "caboose". */
export const LETTER_X: readonly number[] = WORD.reduce<number[]>((xs, letter, index) => {
  if (index === 0) return [0]
  const before = GLYPHS[WORD[index - 1]!]
  xs.push(round(xs[index - 1]! + before.ink[1] + GAPS[index - 1]! - GLYPHS[letter].ink[0]))
  return xs
}, [])

/** The word's right edge: where the e's ink ends, and where the rail ends with it. */
const WORD_END = LETTER_X[WORD.length - 1]! + GLYPHS.e.ink[1]

/**
 * The rail spans the word exactly: its round caps (radius 6) end flush with the c's left
 * edge and the e's right edge. The ties show on the stretch inside the caps.
 */
export const RAIL = { from: 6, to: WORD_END - 6 } as const
const TRACK = { from: RAIL.from, to: RAIL.to } as const

/**
 * Wordmark view box: x, y, width, height. It holds the rail's caps and the b's ascender
 * with a little room, and the ties under the rail while they show.
 */
export const WORDMARK_VIEWBOX = [-4, -42, WORD_END + 8, 172] as const

/** Motion timeline (seconds). The iOS port mirrors these. */
export const TIMING = {
  rail: { delay: 0.05, duration: 0.7 },
  letter: (index: number) => round(0.25 + index * 0.07),
  draw: 0.55,
  hubAfter: 0.5,
  pop: 0.45,
  roll: { delay: 0.7, duration: 3.2, turns: 3 },
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
    ${base}
    @media (prefers-reduced-motion: reduce) { ${s} * { animation: none !important; } }`
  if (motion === 'rolling') {
    return `${common}
    ${s} .wheel { animation: cb-turn 1.8s linear infinite; }
    ${s} .ties { animation: cb-roll 1.8s linear infinite; }`
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
    ${s} .track { opacity: 0; }`
  // Resting styles are the finished logo, ties hidden; every animation fills backwards
  // or not at all, so a renderer that ignores animation (or a reader with reduced motion)
  // still sees the whole still logo.
  if (motion === 'idle') {
    const first = TIMING.idleDelay
    return `${common}${cycles}
    ${s} .wheel { animation: cb-turn-cycle ${cycle}s linear ${first}s infinite; }
    ${s} .ties { animation: cb-roll-cycle ${cycle}s linear ${first}s infinite; }
    ${s} .track { animation: cb-ties-cycle ${cycle}s linear ${first}s infinite; }`
  }
  const ease = 'cubic-bezier(.4,0,.2,1)'
  const rollEase = 'cubic-bezier(.3,.1,.2,1)'
  return `${common}${cycles}
    @keyframes cb-draw { from { stroke-dashoffset: 1; } }
    @keyframes cb-fade { from { opacity: 0; } }
    @keyframes cb-pop { from { opacity: 0; transform: scale(.2); } }
    @keyframes cb-roll-in { from { transform: translateX(${travel}px); } }
    @keyframes cb-turn-in { from { transform: rotate(-${360 * turns}deg); } }
    ${s} .st { stroke-dasharray: 1; animation: cb-draw ${draw}s ${ease} var(--d) backwards; }
    ${s} .rail { stroke-dasharray: 1; animation: cb-draw ${rail.duration}s ${ease} ${rail.delay}s backwards; }
    ${s} .spoke { animation: cb-fade .3s ease-out var(--d) backwards; }
    ${s} .pop { animation: cb-pop ${pop}s cubic-bezier(.34,1.56,.64,1) var(--d) backwards; }
    ${s} .wheel { animation: cb-turn-in ${roll.duration}s ${rollEase} ${roll.delay}s backwards, cb-turn-cycle ${cycle}s linear ${roll.delay + cycle}s infinite; }
    ${s} .ties { animation: cb-roll-in ${roll.duration}s ${rollEase} ${roll.delay}s backwards, cb-roll-cycle ${cycle}s linear ${roll.delay + cycle}s infinite; }
    ${s} .track { animation: cb-ties-cycle ${cycle}s linear ${roll.delay}s infinite; }`
}

const delay = (seconds: number) => ` style="--d:${round(seconds)}s"`

/**
 * One o-wheel with its left edge at `x`: rim, spoke and hub. A lit hub is amber; an
 * unlit one (a parked computer) is the ink, faint.
 */
function wheel(x: number, hub: string, start: number, lit = true): string {
  const fill = lit ? `fill="${hub}"` : `fill="${hub}" opacity=".22"`
  return `<g transform="translate(${x} 0)">` +
    `<g class="wheel"${delay(start)}>${ring(50)}` +
    `<path class="spoke" d="M50 50V22" stroke-width="12" stroke-linecap="round"/></g>` +
    `<circle class="pop"${delay(start + TIMING.hubAfter)} cx="50" cy="50" r="10" ${fill} stroke="none"/></g>`
}

/** Ties under the rail, one every TIE, sliding left as the train rolls right. */
function ties(from: number, to: number, ink: string, opacity: number): string {
  let rects = ''
  for (let k = Math.floor(from / TIE); k * TIE < to; k++) {
    rects += `<rect x="${round(k * TIE)}" y="116" width="14" height="11" rx="2"/>`
  }
  return `<g class="ties" fill="${ink}" opacity="${opacity}">${rects}</g>`
}

function open(box: readonly number[], id: string, height: number | undefined, extra = ''): string {
  const size = height === undefined ? '' : ` width="${round((height * box[2]!) / box[3]!)}" height="${height}"`
  return `<svg xmlns="http://www.w3.org/2000/svg" id="${id}" viewBox="${box.join(' ')}"${size} role="img" aria-labelledby="${id}-title"${extra}>` +
    `<title id="${id}-title">Caboose</title>`
}

/** The wordmark: "caboose" on the rail, its o's for wheels. */
export function wordmarkSvg(options: BrandOptions & { lit?: boolean }): string {
  const { ink, amber = AMBER, motion = 'intro', id = 'caboose', height, lit = true } = options
  const letters = WORD.map((letter, index) => {
    const x = LETTER_X[index]!
    const start = TIMING.letter(index)
    if (letter === 'o') return lit ? wheel(x, amber, start) : wheel(x, ink, start, false)
    return `<g transform="translate(${x} 0)"${delay(start)}>${GLYPHS[letter].strokes.join('')}</g>`
  }).join('')
  // The ties show only while the train rolls, so a still logo has none to hide.
  const track = motion === 'none' ? '' :
    `<defs><clipPath id="${id}-track"><rect x="${TRACK.from}" y="100" width="${TRACK.to - TRACK.from}" height="40"/></clipPath></defs>` +
    `<g class="track" clip-path="url(#${id}-track)">${ties(TRACK.from - ROLL * TIMING.roll.turns, TRACK.to, ink, 0.32)}</g>`
  return open(WORDMARK_VIEWBOX, id, height) +
    `<style>${styles(id, motion)}</style>` +
    track +
    `<path class="rail" pathLength="1" d="M${RAIL.from} 106H${RAIL.to}" fill="none" stroke="${ink}" stroke-width="12" stroke-linecap="round"/>` +
    `<g fill="none" stroke="${ink}" stroke-width="20" stroke-linejoin="round">${letters}</g>` +
    `</svg>`
}

/** One o-wheel, as a mark: rim, spoke and amber hub, outer edge 0..100. Reads as ⏻. */
function powerWheel(steel: string, hub: string): string {
  return `<circle cx="50" cy="50" r="40" fill="none" stroke="${steel}" stroke-width="20"/>` +
    // At icon size a round cap leaves a visible notch against the rim; a square end
    // run into the rim merges cleanly.
    `<path d="M50 50V15" stroke="${steel}" stroke-width="12"/>` +
    `<circle cx="50" cy="50" r="10" fill="${hub}"/>`
}

function navyField(id: string): string {
  return `<defs><linearGradient id="${id}-field" x1="0" y1="0" x2="1" y2="1">` +
    `<stop offset="0" stop-color="${ICON_NAVY_TOP}"/><stop offset="1" stop-color="${ICON_NAVY_BOTTOM}"/></linearGradient></defs>`
}

/**
 * The app icon, 1024 square: one wheel of the wordmark, large, on a navy field. It
 * reads as a power button, which is what opening Caboose does. Static: iOS icons do
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
    `     change brand.ts and run \`pnpm -F caboose-web test -u\`. The rail draws, "caboose" writes\n` +
    `     itself in, the amber hubs pop, and the train rolls three wheel-turns over ties that show only for\n` +
    `     the ride, then again every ${TIMING.cycle} s. Resting styles are the finished logo, so still renderers\n` +
    `     show it complete. -->\n`
  return note + wordmarkSvg({ ink: scheme === 'light' ? INK_LIGHT : INK_DARK, motion: 'intro', height: 120 }) + '\n'
}
