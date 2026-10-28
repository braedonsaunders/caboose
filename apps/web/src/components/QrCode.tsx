import * as React from 'react'
import qrcode from 'qrcode-generator'

/**
 * A QR code drawn as SVG, black on white in every theme so any camera reads it. Each dark
 * module is one unit square of a single path.
 */
export function QrCode({ value, size = 192, label }: { value: string; size?: number; label: string }) {
  const { count, path } = React.useMemo(() => {
    const code = qrcode(0, 'M')
    code.addData(value)
    code.make()
    const modules = code.getModuleCount()
    let d = ''
    for (let row = 0; row < modules; row++) {
      for (let column = 0; column < modules; column++) if (code.isDark(row, column)) d += `M${column} ${row}h1v1h-1z`
    }
    return { count: modules, path: d }
  }, [value])
  const quiet = 4
  return (
    <svg
      role="img"
      aria-label={label}
      width={size}
      height={size}
      viewBox={`${-quiet} ${-quiet} ${count + quiet * 2} ${count + quiet * 2}`}
      shapeRendering="crispEdges"
      className="shrink-0 rounded-md"
    >
      <rect x={-quiet} y={-quiet} width={count + quiet * 2} height={count + quiet * 2} fill="#ffffff" />
      <path d={path} fill="#000000" />
    </svg>
  )
}
