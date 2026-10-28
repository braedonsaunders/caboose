/** The computer's home over `/v1/fs` (docs/architecture.md, Files). Paths are home-relative; "" is the home. */

export interface FileItem {
  name: string
  kind: 'file' | 'directory'
  size: number
  /** Unix milliseconds. */
  mtime: number
  etag: string
  contentType: string
  identity: string
}

/** The host's private staging directory for Craft shortcut jobs, and its in-flight uploads. */
const PRIVATE_NAMES = new Set(['.caboose-jobs'])

/** Splits a home-relative path into its folders; anything the host would reject yields null. */
export function pathParts(path: string): string[] | null {
  if (path === '') return []
  if (path.startsWith('/') || path.includes('\0')) return null
  const parts = path.split('/')
  return parts.every(part => part && part !== '.' && part !== '..') ? parts : null
}

/** The path the address bar asks for, or the home when it is not a valid home-relative path. */
export function normalizeFsPath(raw: string | null | undefined): string {
  const trimmed = (raw ?? '').replace(/^\/+|\/+$/g, '')
  return pathParts(trimmed) ? trimmed : ''
}

export function joinPath(directory: string, name: string): string {
  return directory ? `${directory}/${name}` : name
}

export function parentPath(path: string): string {
  const index = path.lastIndexOf('/')
  return index < 0 ? '' : path.slice(0, index)
}

/** Breadcrumbs from the home to the folder, each with the path it opens. */
export function breadcrumbs(path: string): Array<{ name: string; path: string }> {
  const parts = pathParts(path) ?? []
  return [{ name: 'Home', path: '' }, ...parts.map((name, index) => ({ name, path: parts.slice(0, index + 1).join('/') }))]
}

/** Why a name cannot be used for a new file or folder, or undefined when it can. */
export function nameProblem(name: string): string | undefined {
  if (!name.trim()) return 'Enter a name.'
  if (name !== name.trim()) return 'A name cannot start or end with a space.'
  if (name === '.' || name === '..' || name.includes('/') || name.includes('\0')) return 'A name cannot contain “/” or be “.” or “..”.'
  if (name.startsWith('.caboose-upload-')) return 'That name is reserved for uploads in progress.'
  if (new TextEncoder().encode(name).length > 255) return 'That name is too long.'
  return undefined
}

export type FileSortKey = 'name' | 'size' | 'mtime'

/** Folders first, then by the chosen column; hidden items only when asked for, and never Caboose's private ones. */
export function visibleItems(items: FileItem[], options: { showHidden: boolean; sort: FileSortKey; dir: 'asc' | 'desc' }): FileItem[] {
  const collator = new Intl.Collator(undefined, { numeric: true, sensitivity: 'base' })
  const direction = options.dir === 'asc' ? 1 : -1
  return items
    .filter(item => !PRIVATE_NAMES.has(item.name) && (options.showHidden || !item.name.startsWith('.')))
    .sort((a, b) => {
      if (a.kind !== b.kind) return a.kind === 'directory' ? -1 : 1
      const byName = collator.compare(a.name, b.name)
      if (options.sort === 'size' && a.kind === 'file') return (a.size - b.size) * direction || byName
      if (options.sort === 'mtime') return (a.mtime - b.mtime) * direction || byName
      return byName * direction
    })
}

/** The name the n-th copy gets when the name is taken: "report (2).pdf", as the host's own uploads do. */
export function numberedName(name: string, n: number): string {
  if (n <= 1) return name
  const dot = name.lastIndexOf('.')
  const stem = dot > 0 ? name.slice(0, dot) : name
  const ext = dot > 0 ? name.slice(dot) : ''
  return `${stem} (${n})${ext}`
}

export function formatBytes(bytes: number): string {
  if (!Number.isFinite(bytes) || bytes < 0) return '—'
  if (bytes < 1024) return `${bytes} B`
  const units = ['KB', 'MB', 'GB', 'TB']
  let value = bytes / 1024
  let unit = 0
  while (value >= 1024 && unit < units.length - 1) {
    value /= 1024
    unit++
  }
  return `${value >= 10 ? Math.round(value) : value.toFixed(1)} ${units[unit]}`
}

/** Encodes a home-relative path for the `path` query parameter. */
export function fsQuery(path: string): string {
  return `path=${encodeURIComponent(path)}`
}
