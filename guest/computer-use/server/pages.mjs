// Page tools (webmcp/): the Caboose WebMCP extension's native host listens beside the browser
// process that owns the window, at $XDG_RUNTIME_DIR/caboose-webmcp/<pid>.sock, one JSON request
// per line and one reply per line.
import { createConnection } from 'node:net'
import { join } from 'node:path'
import { env, focusedPid } from './seat.mjs'

export function pageRequest(pid, request, timeout = 25_000) {
  const path = join(env.XDG_RUNTIME_DIR || `/run/user/${process.getuid()}`, 'caboose-webmcp', `${pid}.sock`)
  return new Promise((resolve, reject) => {
    const socket = createConnection(path)
    let data = ''
    const timer = setTimeout(() => { socket.destroy(); reject(new Error('the page did not answer')) }, timeout)
    socket.on('connect', () => socket.write(JSON.stringify(request) + '\n'))
    socket.on('data', chunk => {
      data += chunk
      if (!data.includes('\n')) return
      clearTimeout(timer); socket.end()
      try { resolve(JSON.parse(data.split('\n')[0])) } catch { reject(new Error('invalid page reply')) }
    })
    socket.on('error', error => { clearTimeout(timer); reject(error) })
  })
}

/** A tool's parameters on one line: `name?: type`, an enum as its values. */
export const schemaLine = schema => Object.entries(schema?.properties ?? {}).map(([key, p]) =>
  `${key}${(schema.required ?? []).includes(key) ? '' : '?'}: ${p.enum ? p.enum.slice(0, 12).map(v => JSON.stringify(v)).join('|') + (p.enum.length > 12 ? '|…' : '') : p.type ?? 'any'}`).join(', ')

/** The focused browser tab's tools as lines, or '' where there are none. */
export async function pageTools() {
  const pid = await focusedPid()
  if (!pid) return ''
  let reply
  try { reply = await pageRequest(pid, { op: 'tools' }, 5000) } catch { return '' }
  if (!reply.ok || !reply.result?.tools?.length) return ''
  return [`Page tools (${reply.result.title || reply.result.url}):`,
    ...reply.result.tools.map(t => `${t.name}(${schemaLine(t.inputSchema)})${t.source === 'derived' ? ' [derived]' : ''} — ${String(t.description ?? '').slice(0, 200)}`)].join('\n')
}

const resultText = result => (result?.content ?? []).map(part => part.text ?? (part.type ? `[${part.type}]` : '')).join(' ').slice(0, 4000) || JSON.stringify(result ?? null).slice(0, 4000)

/** Calls one of the focused tab's tools; its result as text. */
export async function callPageTool(name, args) {
  const pid = await focusedPid()
  let reply
  try { reply = await pageRequest(pid, { op: 'call', name, args }) } catch { throw new Error('the focused window offers no page tools') }
  if (!reply.ok) throw new Error(`${name}: ${reply.error}`)
  return `${name}: ${resultText(reply.result)}`
}
