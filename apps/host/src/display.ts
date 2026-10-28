import type { AgentGuest } from './agents.js'

/**
 * The computer's two Caboose Display instances (docs/display.md). The owner's display serves
 * WebSocket port 14600; the agent seat, started when an agent task needs it, serves 14601.
 * Each writes the environment its apps need (its Wayland socket, Xwayland's display and
 * cookie, toolkit and driver hints) to an env file once it is ready; the host reads the
 * owner's at each wake, and agent tasks source the seat's when they start.
 */
export const OWNER_DISPLAY_PORT = 14600
export const AGENT_DISPLAY_PORT = 14601
export const DISPLAY_ENV_PATH = '/run/caboose/display.env'
export const AGENT_DISPLAY_ENV_PATH = '/run/caboose/agent-display.env'
/** The per-wake token both instances and the file service check, written by the host. */
export const DISPLAY_TOKEN_PATH = '/run/caboose/display-token'

/** Writes the per-wake token as root, readable only by `caboose`. Never with a trailing newline. */
export const WRITE_TOKEN_SCRIPT = `install -d -m 0755 /run/caboose; printf %s "$1" > ${DISPLAY_TOKEN_PATH}; chown caboose:caboose ${DISPLAY_TOKEN_PATH}; chmod 0600 ${DISPLAY_TOKEN_PATH}`

export class DisplayNotReadyError extends Error {
  constructor() { super("the computer's display is not ready") }
}

/** The owner display's launch environment; the display is not ready until it has one. */
export function ownerEnv(guest: AgentGuest): string[] {
  if (!guest.ownerEnv?.length) throw new DisplayNotReadyError()
  return guest.ownerEnv
}

/** The X display (Xwayland's) in a launch environment. */
export function x11Display(env: string[]): string {
  const value = env.filter(pair => pair.startsWith('DISPLAY=')).pop()?.slice('DISPLAY='.length)
  if (!value) throw new DisplayNotReadyError()
  return value
}

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
