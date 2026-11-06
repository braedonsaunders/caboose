// One `act` step: a control pressed or set by id or by name, a key, typed text, a pointer
// gesture, a window focused, a wait, a launch, or a page or direct tool called.
import { a11y, launch, markInput, owning, seat, since } from './seat.mjs'
import { observer } from './view.mjs'
import { DIRECT_GROUPS, callDirectTool } from './direct.mjs'
import { callPageTool } from './pages.mjs'

const BUTTONS = { 1: 'left', 2: 'middle', 3: 'right' }
// X keysym names of the printable ASCII characters that are not their own name.
const KEYSYMS = { ' ': 'space', '!': 'exclam', '"': 'quotedbl', '#': 'numbersign', '$': 'dollar', '%': 'percent', '&': 'ampersand',
  "'": 'apostrophe', '(': 'parenleft', ')': 'parenright', '*': 'asterisk', '+': 'plus', ',': 'comma', '-': 'minus', '.': 'period',
  '/': 'slash', ':': 'colon', ';': 'semicolon', '<': 'less', '=': 'equal', '>': 'greater', '?': 'question', '@': 'at',
  '[': 'bracketleft', '\\': 'backslash', ']': 'bracketright', '^': 'asciicircum', '_': 'underscore', '`': 'grave',
  '{': 'braceleft', '|': 'bar', '}': 'braceright', '~': 'asciitilde', '\n': 'Return', '\t': 'Tab' }

export function int(value, name) {
  if (!Number.isInteger(value) || value < -100000 || value > 100000) throw new Error(`${name} must be an integer`)
  return String(value)
}
export function text(value, name, max) {
  if (typeof value !== 'string' || !value.trim()) throw new Error(`${name} must be a non-empty string`)
  if (value.length > max) throw new Error(`${name} must be at most ${max} characters`)
  return value
}
const point = (value, name, size) => {
  if (!Array.isArray(value) || value.length !== size) throw new Error(`${name} must be [${size === 2 ? 'x,y' : 'x1,y1,x2,y2'}]`)
  return value.map((v, i) => int(v, `${name}[${i}]`))
}

/** The key presses that type `value`, or null where it holds a character the keyboard has no key for. */
export function keysFor(value) {
  const keys = [...value].map(c => KEYSYMS[c] ?? (/^[A-Za-z0-9]$/.test(c) ? c : null))
  return value && keys.every(Boolean) ? keys : null
}

// The window an element id names must still have the keyboard (or own the open menu that does).
async function inFocusedWindow(id) {
  if (parseInt(id.split('-')[0], 16) !== owning(await seat('windows'))?.id) {
    throw new Error('stale id: the focused window changed, so nothing was done; look, then retry with its ids (safe to retry)')
  }
}

// An id that no longer resolves did nothing: say so, so a caller knows a retry is safe.
async function stale(action) {
  try { return await action() } catch (error) {
    if (/element not found/.test(error.message)) throw new Error('stale id: the control changed or is gone, so nothing was done; look, then retry with its new id (safe to retry)')
    throw error
  }
}

// The one control of the focused window with this name (and role, when given). A window that
// is still opening is read again, for up to 1.5 s.
async function byName({ name, role }) {
  if (typeof name !== 'string' || !name) throw new Error('a named control needs a name, e.g. {"name":"Save","role":"button"}')
  const wanted = name.replace(/[\s:]+$/, '').toLowerCase()
  const deadline = performance.now() + 1500
  for (;;) {
    const { elements } = await a11y('find', { query: name })
    const match = (elements ?? []).filter(e => (e.name ?? '').replace(/[\s:]+$/, '').toLowerCase() === wanted
      && (!role || e.role === role || e.role.endsWith(` ${role}`)))
    if (match.length === 1) return match[0].id
    if (match.length > 1) throw new Error(`more than one ${role ?? 'control'} "${name}" in the window; use its id from look`)
    if (performance.now() > deadline) throw new Error(`no ${role ?? 'control'} "${name}" in the focused window`)
    await new Promise(resolve => setTimeout(resolve, 100))
  }
}

// The control a press or set names. One named rather than given by id is found when the step
// runs, in whatever window has focus then, so one act can go through a dialog the steps before
// it open; the tree can still describe the window that had focus a moment ago, so it is looked
// for again until the name is in the window that has focus.
async function target(value) {
  if (value && typeof value === 'object') {
    const deadline = performance.now() + 1500
    for (;;) {
      const id = await byName(value)
      try { await inFocusedWindow(id); return id } catch (error) {
        if (performance.now() > deadline) throw error
        await new Promise(resolve => setTimeout(resolve, 100))
      }
    }
  }
  const id = observer.resolve(text(value, 'id', 500))
  await inFocusedWindow(id)
  return id
}

async function type(value) {
  markInput(true)
  // Text on the keyboard's layout goes in as key presses, in order with the steps around it;
  // anything else (accents, other scripts) as the input method's commit.
  const keys = keysFor(value)
  if (keys) {
    for (let i = 0; i < keys.length; i += 200) await seat('key', '--', ...keys.slice(i, i + 200))
  } else await seat('type', '--', value)
}

/** Runs one step; returns a note for the reply, if any. */
export async function step(s) {
  if (!s || typeof s !== 'object') throw new Error('a step is an object such as {"press":"e3"}')
  if ('press' in s) {
    const id = await target(s.press)
    await stale(() => a11y('act', { element: id, action: 'press' }))
    return
  }
  if ('set' in s) {
    const id = await target(s.set)
    if (typeof s.text !== 'string' || s.text.length > 100_000) throw new Error('set needs text, a string of at most 100000 characters')
    return (await stale(() => a11y('act', { element: id, action: 'set-text', text: s.text }))).note
  }
  if ('tool' in s) {
    const name = text(s.tool, 'tool', 200)
    if (s.args !== undefined && (typeof s.args !== 'object' || s.args === null || Array.isArray(s.args))) throw new Error('args must be an object')
    markInput()
    return DIRECT_GROUPS.test(name) ? callDirectTool(name, s.args ?? {}, type) : callPageTool(name, s.args ?? {})
  }
  markInput()
  if ('key' in s) {
    if (typeof s.key !== 'string' || !/^[A-Za-z0-9_+]+$/.test(s.key)) throw new Error('key must look like "ctrl+s" or "Return"')
    const repeat = s.repeat ?? 1
    if (!Number.isInteger(repeat) || repeat < 1 || repeat > 50) throw new Error('repeat must be 1–50')
    for (let i = 0; i < repeat; i++) await seat('key', '--', s.key)
  } else if ('type' in s) {
    if (typeof s.type !== 'string') throw new Error('type must be a string')
    await type(s.type)
  } else if ('click' in s) {
    const [x, y] = point(s.click, 'click', 2), button = s.button ?? 1, count = s.count ?? 1
    if (!BUTTONS[button]) throw new Error('button must be 1 (left), 2 (middle) or 3 (right)')
    if (![1, 2, 3].includes(count)) throw new Error('count must be 1, 2 or 3')
    await seat('click', x, y, '--button', BUTTONS[button], '--count', String(count))
  } else if ('scroll' in s) {
    const [x, y] = point(s.scroll, 'scroll', 2)
    const clamp = (value, name) => String(Math.max(-50, Math.min(50, Number(int(value ?? 0, name)))))
    await seat('scroll', x, y, clamp(s.dx, 'dx'), clamp(s.dy, 'dy'))
  } else if ('drag' in s) {
    await seat('drag', ...point(s.drag, 'drag', 4))
  } else if ('focus' in s) {
    if (!Number.isInteger(s.focus)) throw new Error('focus must be a window id')
    await seat('focus', String(s.focus))
  } else if ('wait' in s) {
    if (!Number.isInteger(s.wait) || s.wait < 10 || s.wait > 5000) throw new Error('wait must be 10–5000 ms')
    // At most that long, and no longer than the windows take to stop drawing: every step
    // already waits for the application's reaction, so a wait mostly lets a slow one finish.
    const until = performance.now() + s.wait
    let settled = true
    try { await seat('settle', 'quiet', ...since()) } catch { settled = false }
    const left = settled ? Math.min(until - performance.now(), 200) : until - performance.now()
    if (left > 0) await new Promise(resolve => setTimeout(resolve, left))
  } else if ('launch' in s) {
    await launch(text(s.launch, 'launch', 2000))
  } else throw new Error('unknown step; use press, set, key, type, click, scroll, drag, focus, wait, launch or tool')
}
