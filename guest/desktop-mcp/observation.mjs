// The agent's view of the seat as compact text: the focused window (the others only as a
// count), then its controls one per line under short ids (e1, e2, …). After the first observation of a
// window, later ones carry only what changed: controls added, removed or changed, and windows
// opened, closed or focused. Short ids stay the same for a control as long as the server
// runs, so the model refers back to a line it saw several steps ago.
const quote = text => JSON.stringify(text)

export class Observer {
  constructor() {
    this.ids = new Map() // full element id -> short id
    this.full = new Map() // short id -> full element id
    this.next = 1
    this.windows = null // last window listing, by id
    this.seen = new Map() // window id -> (short id -> rendered line) of its last observation
    this.described = new Map() // full element id -> { role, name } as last read
  }

  // The element id a tool argument names: a short id from an observation, or a full id.
  resolve(id) {
    return this.full.get(id) ?? id
  }

  short(id) {
    let short = this.ids.get(id)
    if (!short) {
      short = `e${this.next++}`
      this.ids.set(id, short)
      this.full.set(short, id)
    }
    return short
  }

  line(short, element) {
    const states = (element.states ?? []).filter(s => s !== 'showing' && s !== 'visible')
    return `${short} ${element.role} ${quote(element.name ?? '')}${element.value !== undefined ? ` = ${quote(element.value)}` : ''}` +
      `${states.length ? ` [${states.join(', ')}]` : ''}`
  }

  windowLine(w) {
    return `${w.kind} ${w.id} ${quote(w.title ?? '')} (${w.app_id ?? 'unknown app'})${w.parent != null ? ` of ${w.parent}` : ''}${w.focused ? ', focused' : ''}`
  }

  // `listing`: the seat's windows ({ windows, focused }); `state`: the a11y read of the focused
  // window ({ elements, note? }); `full`: list everything rather than the changes.
  render(listing, state, { full = false } = {}) {
    const lines = []
    const now = new Map(listing.windows.map(w => [w.id, w]))
    const previous = this.windows
    this.windows = now
    if (full || !previous) {
      // The focused window alone; the others are a count (look with windows lists them).
      const focus = now.get(listing.focused)
      const others = listing.windows.length - (focus ? 1 : 0)
      if (focus) lines.push(`In ${this.windowLine(focus)}${others ? ` (${others} other window${others > 1 ? 's' : ''})` : ''}`)
      else lines.push(listing.windows.length ? `No window has the keyboard (${others} open).` : 'No windows are open on the agent seat.')
    } else {
      for (const w of listing.windows) {
        const before = previous.get(w.id)
        if (!before) lines.push(`Opened ${this.windowLine(w)}`)
        else if (before.title !== w.title) lines.push(`Retitled ${w.kind} ${w.id} ${quote(w.title ?? '')}`)
      }
      for (const [id, w] of previous) if (!now.has(id)) lines.push(`Closed ${w.kind} ${id} ${quote(w.title ?? '')}`)
      if (listing.focused !== [...previous.values()].find(w => w.focused)?.id && now.get(listing.focused))
        lines.push(`Focus is on ${now.get(listing.focused).kind} ${listing.focused}`)
    }
    const focused = listing.focused
    if (state?.note && !(state.elements ?? []).length) {
      lines.push(state.note)
      this.seen.delete(focused)
      return lines.join('\n')
    }
    if (state?.partial && (full || !this.seen.has(focused))) lines.push(`(${state.partial})`)
    const current = new Map()
    for (const element of state?.elements ?? []) {
      this.described.set(element.id, { role: element.role, name: element.name ?? '' })
      const short = this.short(element.id)
      current.set(short, this.line(short, element))
    }
    const before = this.seen.get(focused)
    this.seen.set(focused, current)
    if (full || !before) {
      for (const line of current.values()) lines.push(line)
      if (!current.size) lines.push('(none)')
      return lines.join('\n')
    }
    const changes = []
    for (const [short, line] of current) {
      if (!before.has(short)) changes.push(`+ ${line}`)
      else if (before.get(short) !== line) changes.push(`~ ${line}`)
    }
    for (const short of before.keys()) if (!current.has(short)) changes.push(`- ${short}`)
    if (!changes.length) lines.push(lines.length ? 'No change in its controls.' : 'No change.')
    lines.push(...changes)
    return lines.join('\n')
  }
}
