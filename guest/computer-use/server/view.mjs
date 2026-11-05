// The seat as the agent reads it: the focused window's controls, rendered by the Observer in
// full or as what changed since the last read.
import { Observer } from './observation.mjs'
import { a11y, input, owning, seat, since } from './seat.mjs'

export const observer = new Observer()
/** The last accessibility read, with its notes (`note`, `unread` regions). */
export let lastState

/** The display as the observer renders it: everything (`full`), or what changed since the last time. */
export async function view(full) {
  let state = await a11y('elements')
  let listing = await seat('windows')
  // A window that has just opened may not be in its application's tree yet, and a read that
  // raced the focus change describes the window before: read again, for up to 1.5 s, until
  // the read is of the focused window and, for one not seen before, shows controls.
  const stale = () => {
    const focused = owning(listing)
    if (!focused) return false
    if ((state.window?.title ?? '') !== (focused.title ?? '')) return true
    return !(state.elements ?? []).length && !observer.seen.has(listing.focused)
  }
  const deadline = performance.now() + 1500
  while (performance.now() < deadline && stale()) {
    await new Promise(resolve => setTimeout(resolve, 100))
    state = await a11y('elements')
    listing = await seat('windows')
  }
  lastState = state
  return observer.render(listing, state, { full })
}

/** What changed since the last read, once the seat has reacted to the last input. */
export async function changes() {
  // A text edit is processed asynchronously (completion, validation): wait for the window to
  // go quiet. After a press, the first reaction is enough for an accessibility read.
  await seat('settle', input.typed ? 'quiet' : 'react', ...since())
  input.at = undefined; input.typed = false
  return view(false)
}

export function windowLines(windows) {
  return windows.length ? windows.map(w => `${w.kind} ${w.id} ${JSON.stringify(w.title ?? '')} (${w.app_id ?? 'unknown app'})`
    + `${w.parent != null ? ` of ${w.parent}` : ''} at ${w.rect.join(',')}${w.focused ? ', focused' : ''}`).join('\n') : 'No windows are open on the agent seat.'
}
