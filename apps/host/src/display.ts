import type { DisplayProtocol } from './config.js'

/**
 * The owner's display server inside the computer, by the protocol the app speaks to it.
 * Xpra serves X display :100 on 14500. caboose-display (docs/display.md) serves 14600 and
 * writes the environment its apps need (its Wayland socket, Xwayland's display and cookie,
 * toolkit and driver hints) to `/run/caboose/display.env` once it is ready; the host reads
 * that at each wake. The agent seat stays Xpra :101 on 14501 either way.
 */
export interface OwnerDisplay {
  port: number
  /** The launch environment, when it is fixed rather than read from the computer. */
  launchEnv?: string[]
}

export const OWNER_DISPLAYS: Record<DisplayProtocol, OwnerDisplay> = {
  'xpra-ws': { port: 14500, launchEnv: ['DISPLAY=:100'] },
  'caboose-display': { port: 14600 },
}

export const DISPLAY_ENV_PATH = '/run/caboose/display.env'

/**
 * `KEY=value` pairs from an sh environment file: one assignment per line, an optional
 * `export`, values bare, 'single-quoted' or "double-quoted" (with backslash escapes),
 * and `#` comments. Anything that is not an assignment is ignored.
 */
export function parseEnvFile(text: string): string[] {
  const env: string[] = []
  for (const line of text.split('\n')) {
    const words = shellWords(line)
    if (words[0] === 'export') words.shift()
    for (const word of words) {
      const match = /^([A-Za-z_][A-Za-z0-9_]*)=/.exec(word)
      if (match) env.push(word)
    }
  }
  return env
}

function shellWords(line: string): string[] {
  const words: string[] = []
  let word = '', inWord = false, i = 0
  while (i < line.length) {
    const c = line[i]
    if (c === "'") {
      const end = line.indexOf("'", i + 1)
      if (end < 0) return words // unterminated: not a usable line
      word += line.slice(i + 1, end); inWord = true; i = end + 1
    } else if (c === '"') {
      i++
      while (i < line.length && line[i] !== '"') {
        if (line[i] === '\\' && i + 1 < line.length && '$`"\\\n'.includes(line[i + 1]!)) i++
        word += line[i++]
      }
      if (i >= line.length) return words
      inWord = true; i++
    } else if (c === '\\' && i + 1 < line.length) {
      word += line[i + 1]; inWord = true; i += 2
    } else if (c === ' ' || c === '\t') {
      if (inWord) { words.push(word); word = ''; inWord = false }
      i++
    } else if (c === '#' && !inWord) {
      break
    } else {
      word += c; inWord = true; i++
    }
  }
  if (inWord) words.push(word)
  return words
}
