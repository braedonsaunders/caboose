import { AgentInputError, AgentUnavailableError, type AgentGuest } from './agents.js'
import { ownerEnv, x11Display } from './display.js'

/**
 * The owner's display through its accessibility tree, for the iPhone's on-device agent and
 * the web console: list the focused window's controls, act on one, type, press a shortcut.
 * Everything runs as `caboose` with the owner display's launch environment, on its X display
 * (Caboose Display's Xwayland), through /opt/caboose/a11y.py (see
 * guest/desktop-mcp) and xdotool. See docs/architecture.md § Screen.
 */
const A11Y = '/opt/caboose/a11y.py'
const ELEMENT_ID = /^[\x21-\x7e]{1,200}$/
const ACTIONS = new Set(['press', 'focus', 'set-text'])
/** One or more xdotool key combinations: `ctrl+s`, `alt+f4`, `ctrl+shift+t Return`. */
const KEYS = /^[A-Za-z0-9_]+(\+[A-Za-z0-9_]+)*( [A-Za-z0-9_]+(\+[A-Za-z0-9_]+)*){0,9}$/
const MAX_TEXT = 10_000

export interface ScreenElement { id: string; role: string; name: string; states: string[]; bounds: { x: number; y: number; width: number; height: number } }
export interface ScreenElements { window: { title: string; app: string }; elements: ScreenElement[]; note?: string }

export class ScreenElementGoneError extends Error {
  constructor() { super('element not found') }
}

/**
 * Runs a command as `caboose` on the owner's display and reports its exit status with its
 * output, since the guest channel rejects a non-zero exit without saying which.
 */
export const ON_DISPLAY = [
  'd=$1; shift; err="${TMPDIR:-/tmp}/caboose-screen.$$"',
  'out=$(env HOME=/home/caboose DISPLAY="$d" "$@" 2>"$err") && code=0 || code=$?',
  // Diagnostics only on failure, so warnings on stderr never corrupt a JSON answer.
  '[ "$code" = 0 ] || out="$out $(tail -c 300 "$err")"',
  'rm -f "$err"',
  'printf "%s\\n%s" "$code" "$out"',
].join('\n')

/** Runs `args(display)` on the owner's display, `display` being its X display. */
async function onDisplay(guest: AgentGuest | undefined, args: (display: string) => string[]): Promise<{ code: number; out: string }> {
  if (!guest) throw new AgentUnavailableError()
  const env = ownerEnv(guest)
  const display = x11Display(env)
  const out = await guest.run('/usr/sbin/runuser', ['-u', 'caboose', '--', '/usr/bin/env', ...env, '/bin/sh', '-c', ON_DISPLAY, 'sh', display, ...args(display)], 20_000)
  const newline = out.indexOf('\n')
  return { code: Number(out.slice(0, newline < 0 ? undefined : newline)), out: newline < 0 ? '' : out.slice(newline + 1) }
}

function parse(out: string): any {
  try { return JSON.parse(out) } catch { throw new Error(`a11y.py answered with something other than JSON: ${out.slice(0, 200)}`) }
}

export async function screenElements(guest: AgentGuest | undefined): Promise<ScreenElements> {
  const { code, out } = await onDisplay(guest, display => ['/usr/bin/python3', A11Y, 'elements', '--display', display])
  if (code !== 0) throw new Error(`a11y.py elements failed (${code}): ${out.slice(0, 300)}`)
  const value = parse(out)
  return {
    window: value.window ?? { title: '', app: '' }, elements: Array.isArray(value.elements) ? value.elements.slice(0, 200) : [],
    // Why the list is empty: no focused window, no accessibility tree, or an app on both displays.
    ...(typeof value.note === 'string' && value.note ? { note: value.note } : {}),
  }
}

export async function screenAct(guest: AgentGuest | undefined, input: Record<string, unknown>): Promise<{ ok: true }> {
  const { element, action, text } = input
  if (typeof element !== 'string' || !ELEMENT_ID.test(element)) throw new AgentInputError('element must be an element id from /v1/screen/elements')
  if (typeof action !== 'string' || !ACTIONS.has(action)) throw new AgentInputError('action must be "press", "focus" or "set-text"')
  if (action === 'set-text' && (typeof text !== 'string' || text.length > MAX_TEXT)) throw new AgentInputError('set-text needs text of at most 10000 characters')
  const { code, out } = await onDisplay(guest, display => ['/usr/bin/python3', A11Y, 'act', '--display', display, '--element', element, '--action', action,
    ...(action === 'set-text' ? ['--text', text as string] : [])])
  if (code === 3) throw new ScreenElementGoneError()
  if (code !== 0) throw new Error(`a11y.py act failed (${code}): ${out.slice(0, 300)}`)
  return { ok: true }
}

export async function screenType(guest: AgentGuest | undefined, input: Record<string, unknown>): Promise<{ ok: true }> {
  if (typeof input.text !== 'string' || !input.text || input.text.length > MAX_TEXT) throw new AgentInputError('text must be 1–10000 characters')
  const { code, out } = await onDisplay(guest, () => ['/usr/bin/xdotool', 'type', '--clearmodifiers', '--delay', '4', '--', input.text as string])
  if (code !== 0) throw new Error(`xdotool type failed (${code}): ${out.slice(0, 300)}`)
  return { ok: true }
}

export async function screenKeys(guest: AgentGuest | undefined, input: Record<string, unknown>): Promise<{ ok: true }> {
  const keys = typeof input.keys === 'string' ? input.keys.trim() : ''
  if (!KEYS.test(keys)) throw new AgentInputError('keys must be key combinations such as "ctrl+s" or "ctrl+shift+t", separated by spaces')
  const { code, out } = await onDisplay(guest, () => ['/usr/bin/xdotool', 'key', '--clearmodifiers', ...keys.split(' ').map(normalizeKey)])
  if (code !== 0) throw new Error(`xdotool key failed (${code}): ${out.slice(0, 300)}`)
  return { ok: true }
}

/** Common names to X keysyms: `enter` → `Return`, `esc` → `Escape`, `cmd`/`win` → `super`. */
export function normalizeKey(combo: string): string {
  const names: Record<string, string> = {
    enter: 'Return', return: 'Return', esc: 'Escape', escape: 'Escape', tab: 'Tab', space: 'space', backspace: 'BackSpace',
    delete: 'Delete', del: 'Delete', up: 'Up', down: 'Down', left: 'Left', right: 'Right', home: 'Home', end: 'End',
    pageup: 'Prior', pagedown: 'Next', cmd: 'super', win: 'super', meta: 'super', control: 'ctrl', option: 'alt',
  }
  return combo.split('+').map(part => names[part.toLowerCase()] ?? (/^f\d{1,2}$/i.test(part) ? part.toUpperCase() : part.length === 1 ? part.toLowerCase() : part)).join('+')
}
