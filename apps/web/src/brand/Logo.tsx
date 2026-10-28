import * as React from 'react'
import { wordmarkSvg, type Motion } from './brand.js'

// The console's brand: the wordmark from brand.ts, the same markup as the README
// files, drawn in the current text colour so it follows the light and dark theme.
//
//   <Wordmark motion="intro" />    draws itself in and rolls, then rolls now and then (sign-in)
//   <Wordmark motion="idle" />     the still logo, rolling now and then (sidebar)
//   <Wordmark />                   the still logo
//   <Wordmark lit={false} />       hubs unlit: the computer is parked
//   <Wordmark motion="rolling" />  wheels turning (loading)

type WordmarkProps = {
  /** Rendered height in px. */
  height: number
  motion?: Motion
  /** Amber hubs while the computer is up; unlit while it is parked. */
  lit?: boolean
  className?: string
  /** Hide from assistive technology when a visible name sits beside it. */
  decorative?: boolean
}

export function Wordmark({ height, motion = 'none', lit = true, className, decorative }: WordmarkProps) {
  // useId output is not a valid CSS identifier; the id scopes the logo's styles.
  const id = 'cb-word' + React.useId().replace(/[^a-zA-Z0-9_-]/g, '')
  const markup = React.useMemo(
    () => wordmarkSvg({ ink: 'currentColor', motion, id, height, lit }),
    [motion, id, height, lit])
  return (
    <span
      className={['inline-flex shrink-0 leading-none', className].filter(Boolean).join(' ')}
      aria-hidden={decorative || undefined}
      dangerouslySetInnerHTML={{ __html: markup }}
    />
  )
}

/** A busy state in the brand's voice: the wordmark rolling over its label. */
export function RollingWordmark({ label }: { label: string }) {
  return (
    <div role="status" className="flex flex-col items-center justify-center gap-4 py-16 text-fg-muted">
      <Wordmark height={44} motion="rolling" className="text-foreground" decorative />
      <span className="text-sm">{label}</span>
    </div>
  )
}
