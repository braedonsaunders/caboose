// The tool contract (docs/architecture.md § Computer use): three tools, kept short, since
// their definitions go to the model on every turn, and the instructions the server gives the
// agent when it connects.
import { mkdtemp, readFile, rm } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { a11y, seat, since } from './seat.mjs'
import { changes, lastState, observer, view, windowLines } from './view.mjs'
import { step, text } from './steps.mjs'
import { pageTools } from './pages.mjs'
import { directLines, directTools, toolLine, windowPaths } from './direct.mjs'
import { pixelFallback, unreadWords, windowWords } from './pixels.mjs'

export const INSTRUCTIONS = 'These tools see and drive applications on the agent seat, your own display on the computer '
  + '(the owner can watch it live). Read it with look, act on controls by id, and batch the steps you know in one act; '
  + 'each act replies with what changed. Prefer an app\'s direct tools and page tools to its GUI. Start an app with '
  + 'an act step {"launch":"command"}; use screenshot only for what the controls do not tell.'

export const TOOLS = [
  {
    name: 'look',
    description: 'The focused window\'s controls from its accessibility tree, one per line: id role "name" = value [states], '
      + 'the page\'s tools in a browser, and the app\'s direct tools. find: only controls and direct tools whose name contains it. text: also the window\'s readable text '
      + '(documents, pages, terminals). windows: every window, with its id and position. ocr: also the words read from the '
      + 'window\'s pixels with their positions, for areas the controls leave out (icon views, canvases).',
    inputSchema: { type: 'object', properties: { find: { type: 'string' }, text: { type: 'boolean' }, windows: { type: 'boolean' }, ocr: { type: 'boolean' } } },
  },
  {
    name: 'act',
    description: 'Run steps in order, stopping at the first failure; then reply with what changed (+ added, ~ changed, - removed '
      + 'controls; windows opened or closed). Put every step you already know in one call; a control in a dialog that an earlier '
      + 'step opens can be named instead of given by id ({"name":"Save","role":"button"}). A step is one of: {"press":id} '
      + '{"set":id,"text":t} replaces a field\'s text (plain; type keeps formatting), {"key":"ctrl+s"}, {"type":t}, {"click":[x,y],"button":1-3,"count":1-3}, '
      + '{"scroll":[x,y],"dy":n}, {"drag":[x1,y1,x2,y2]}, {"focus":window}, {"launch":"command"}, '
      + '{"tool":name,"args":{...}} calls a page tool or a direct tool (look lists the app\'s; files.list|read|write|copy|'
      + 'move|mkdir|trash|extract in the home always work). Direct tools skip the GUI: prefer them. Steps wait for the app to react; {"wait":ms} is rarely needed.',
    inputSchema: { type: 'object', properties: { steps: { type: 'array', items: { type: 'object' } } }, required: ['steps'] },
  },
  {
    name: 'screenshot',
    description: 'A picture of the seat, or of one window. Only for what the controls do not tell; coordinates are its pixels. '
      + 'marks: number the controls on it.',
    inputSchema: { type: 'object', properties: { window: { type: 'integer' }, marks: { type: 'boolean' } } },
  },
]

/** Each act step's timing (`key:12`, `tool=files.read:40`, `observe:300`), for the trace. */
export let lastTiming = []

const PRESSING = x => x && typeof x === 'object' && ('press' in x || 'key' in x || 'click' in x)
const SHORTCUT = /(^|\+)(ctrl|alt|super|control|meta)\+/i

export const handlers = {
  async look({ find, text: withText = false, windows = false, ocr: withOcr = false } = {}) {
    const parts = []
    if (windows) parts.push(windowLines((await seat('windows')).windows))
    if (find !== undefined) {
      const { elements, note } = await a11y('find', { query: text(find, 'find', 500) })
      const lines = (elements ?? []).map(e => observer.line(observer.short(e.id), e))
      const query = find.toLowerCase()
      const tools = (await directTools().catch(() => [])).filter(t => t.name.toLowerCase().includes(query)).map(toolLine)
      if (tools.length) lines.push('Direct tools:', ...tools)
      parts.push(lines.length ? lines.join('\n') : (note ?? 'No control matches.'))
    } else {
      parts.push(await view(true))
      const tools = await pageTools()
      if (tools) parts.push(tools)
      // The files and folders the window works on, so paths need no guessing.
      const paths = await windowPaths().catch(() => [])
      if (paths.length) parts.push(`Its files: ${paths.join(', ')}`)
      const direct = await directLines().catch(() => '')
      if (direct) parts.push(direct)
      if (lastState?.unread?.length) {
        const words = await unreadWords(lastState.unread).catch(() => '')
        if (words) parts.push(words)
      }
      if (lastState?.note && !(lastState.elements ?? []).length && lastState.window) {
        const pictured = await pixelFallback().catch(() => [])
        if (pictured.length) return [{ type: 'text', text: parts.join('\n') }, ...pictured]
      }
    }
    if (withText) parts.push(`Text:\n${(await a11y('text')).text ?? ''}`)
    if (withOcr) parts.push(await windowWords().catch(error => `No text could be read from pixels: ${error.message}`))
    return [{ type: 'text', text: parts.join('\n') }]
  },

  async act({ steps, observe = true }) {
    if (!Array.isArray(steps) || steps.length < 1 || steps.length > 30) throw new Error('steps must hold 1–30 steps')
    let windowsBefore = null
    try { windowsBefore = new Set((await seat('windows')).windows.map(w => w.id)) } catch {}
    let done = 0, error, after
    const notes = [], timing = []
    for (const s of steps) {
      try {
        // Typed text reaches an application as an input method's commit, keys as key events,
        // and it may take them out of order: after typing, the next step waits until the
        // window has drawn it.
        if (after === 'type' && s && typeof s === 'object' && !('wait' in s)) await seat('settle', 'quiet', ...since())
        // A shortcut's command can run after the key event, once the application gets to it
        // (LibreOffice's ctrl+b): let it react before more input, or the text typed next can
        // arrive first.
        if (after === 'shortcut' && s && typeof s === 'object' && ('type' in s || 'key' in s)) await seat('settle', 'react', ...since())
        const began = performance.now()
        const note = await step(s); if (note) notes.push(note); done++
        timing.push(`${Object.keys(s ?? {})[0]}${s && typeof s.tool === 'string' ? `=${s.tool}` : ''}:${Math.round(performance.now() - began)}`)
        after = s && typeof s === 'object' && 'type' in s ? 'type' : s && typeof s === 'object' && typeof s.key === 'string' && SHORTCUT.test(s.key) ? 'shortcut' : undefined
      } catch (e) { error = e.message; break }
    }
    const head = done === steps.length ? (steps.length > 1 ? `Done ${done} steps.` : 'Done.') : `Did ${done} of ${steps.length}; stopped: ${error}`
    const content = [head + (notes.length ? ` (${notes.join('; ')})` : '')]
    if (observe) {
      const began = performance.now()
      try {
        let seen = await changes()
        // An application busy building a window (a first file chooser can take seconds) draws
        // nothing until it maps: after a press, key or click that changed nothing, wait a little
        // for a new window before saying so.
        if (seen === 'No change.' && windowsBefore && done && steps.slice(0, done).some(PRESSING)) {
          const deadline = performance.now() + 2500
          while (performance.now() < deadline) {
            await new Promise(resolve => setTimeout(resolve, 100))
            if ((await seat('windows')).windows.some(w => !windowsBefore.has(w.id))) { seen = await changes(); break }
          }
        }
        content.push(seen)
      } catch (e) { content.push(`Could not read the window: ${e.message}`) }
      timing.push(`observe:${Math.round(performance.now() - began)}`)
    }
    lastTiming = timing
    return [{ type: 'text', text: content.join('\n') }]
  },

  async screenshot({ window, marks = false }) {
    if (window !== undefined && !Number.isInteger(window)) throw new Error('window must be a window id')
    if (typeof marks !== 'boolean') throw new Error('marks must be a boolean')
    const dir = await mkdtemp(join(tmpdir(), 'caboose-shot-'))
    try {
      const file = join(dir, 'seat.png')
      const shot = await seat('screenshot', '--out', file, ...(window === undefined ? [] : ['--window', String(window)]))
      let legend
      if (marks) {
        const { elements } = await a11y('elements')
        ;({ legend } = await seat('annotate', file, shot.rect, elements, window ?? null))
        legend = legend?.map(entry => `${entry.mark} ${observer.short(entry.id)} ${entry.role} ${JSON.stringify(entry.name ?? '')} at ${entry.center.join(',')}`)
      }
      return [{ type: 'image', data: (await readFile(file)).toString('base64'), mimeType: 'image/png' },
        ...(legend ? [{ type: 'text', text: legend.join('\n') }] : [])]
    } finally {
      await rm(dir, { recursive: true, force: true })
    }
  },
}
