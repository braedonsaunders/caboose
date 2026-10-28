import * as React from 'react'
import { carSvg, wordmarkSvg, type Motion } from './brand.js'

// The console's brand components. Both render brand.ts's SVG — the same markup as the
// README files — in the current text colour, so they follow the light and dark theme.
//
//   <Wordmark motion="intro" />   draws itself in and rolls (sign-in)
//   <Car />                       the still mark (sidebar)
//   <Car motion="rolling" />      wheels turning (loading)
//   <Car lights={false} />        a parked car, windows dark

type Common = {
  /** Rendered height in px. */
  height: number
  motion?: Motion
  className?: string
  /** Hide from assistive technology when a visible name sits beside it. */
  decorative?: boolean
}

function useScopeId(prefix: string): string {
  // useId output is not a valid CSS identifier; the id scopes the logo's styles.
  return prefix + React.useId().replace(/[^a-zA-Z0-9_-]/g, '')
}

function Svg({ markup, className, decorative }: { markup: string; className?: string; decorative?: boolean }) {
  return (
    <span
      className={['inline-flex shrink-0 leading-none', className].filter(Boolean).join(' ')}
      aria-hidden={decorative || undefined}
      dangerouslySetInnerHTML={{ __html: markup }}
    />
  )
}

export function Wordmark({ height, motion = 'none', className, decorative }: Common) {
  const id = useScopeId('cb-word')
  const markup = React.useMemo(() => wordmarkSvg({ ink: 'currentColor', motion, id, height }), [motion, id, height])
  return <Svg markup={markup} className={className} decorative={decorative} />
}

export function Car({ height, motion = 'none', lights = true, className, decorative }: Common & { lights?: boolean }) {
  const id = useScopeId('cb-car')
  const markup = React.useMemo(
    () => carSvg({ ink: 'currentColor', motion, id, height, lights, stove: height >= 40 }),
    [motion, id, height, lights])
  return <Svg markup={markup} className={className} decorative={decorative} />
}

/** A busy state in the brand's voice: the car rolling over its label. */
export function RollingCar({ label }: { label: string }) {
  return (
    <div role="status" className="flex flex-col items-center justify-center gap-4 py-16 text-muted-foreground">
      <Car height={56} motion="rolling" className="text-foreground" decorative />
      <span className="text-sm">{label}</span>
    </div>
  )
}
