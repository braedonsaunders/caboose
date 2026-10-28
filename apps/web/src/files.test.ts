import { describe, expect, it } from 'vitest'
import {
  breadcrumbs, formatBytes, fsQuery, joinPath, nameProblem, normalizeFsPath, numberedName, parentPath, pathParts, visibleItems,
  type FileItem,
} from './files.js'

const item = (name: string, kind: 'file' | 'directory', size = 0, mtime = 0): FileItem =>
  ({ name, kind, size, mtime, etag: '"e"', contentType: 'application/octet-stream', identity: `1:${name}` })

describe('files', () => {
  it('accepts only home-relative paths the host accepts, falling back to the home', () => {
    expect(pathParts('')).toEqual([])
    expect(pathParts('Documents/Notes')).toEqual(['Documents', 'Notes'])
    expect(pathParts('/etc')).toBeNull()
    expect(pathParts('a/../b')).toBeNull()
    expect(pathParts('a//b')).toBeNull()
    expect(normalizeFsPath('/Documents/')).toBe('Documents')
    expect(normalizeFsPath('../etc')).toBe('')
    expect(normalizeFsPath(null)).toBe('')
  })

  it('joins, climbs and breadcrumbs paths', () => {
    expect(joinPath('', 'a.txt')).toBe('a.txt')
    expect(joinPath('Documents', 'a.txt')).toBe('Documents/a.txt')
    expect(parentPath('Documents/Notes')).toBe('Documents')
    expect(parentPath('Documents')).toBe('')
    expect(breadcrumbs('Documents/Notes')).toEqual([
      { name: 'Home', path: '' }, { name: 'Documents', path: 'Documents' }, { name: 'Notes', path: 'Documents/Notes' },
    ])
    expect(fsQuery('My Files/a&b.txt')).toBe('path=My%20Files%2Fa%26b.txt')
  })

  it('lists folders first, hides dotfiles unless asked, and never shows Caboose job staging', () => {
    const items = [item('b.txt', 'file', 10, 3), item('Zeta', 'directory'), item('.bashrc', 'file'), item('.caboose-jobs', 'directory'), item('a10.txt', 'file', 30, 1), item('a9.txt', 'file', 20, 2)]
    expect(visibleItems(items, { showHidden: false, sort: 'name', dir: 'asc' }).map(entry => entry.name)).toEqual(['Zeta', 'a9.txt', 'a10.txt', 'b.txt'])
    expect(visibleItems(items, { showHidden: true, sort: 'name', dir: 'asc' }).map(entry => entry.name)).toEqual(['Zeta', '.bashrc', 'a9.txt', 'a10.txt', 'b.txt'])
    expect(visibleItems(items, { showHidden: false, sort: 'size', dir: 'desc' }).map(entry => entry.name)).toEqual(['Zeta', 'a10.txt', 'a9.txt', 'b.txt'])
    expect(visibleItems(items, { showHidden: false, sort: 'mtime', dir: 'desc' }).map(entry => entry.name)).toEqual(['Zeta', 'b.txt', 'a9.txt', 'a10.txt'])
  })

  it('rejects names the file service would refuse', () => {
    expect(nameProblem('Report.pdf')).toBeUndefined()
    expect(nameProblem('')).toBe('Enter a name.')
    expect(nameProblem(' padded')).toMatch(/space/)
    expect(nameProblem('a/b')).toMatch(/“\/”/)
    expect(nameProblem('..')).toMatch(/“\/”/)
    expect(nameProblem('.caboose-upload-123')).toMatch(/reserved/)
    expect(nameProblem('é'.repeat(128))).toMatch(/too long/)
  })

  it('numbers copies like the host and formats sizes', () => {
    expect(numberedName('report.pdf', 1)).toBe('report.pdf')
    expect(numberedName('report.pdf', 2)).toBe('report (2).pdf')
    expect(numberedName('Makefile', 3)).toBe('Makefile (3)')
    expect(numberedName('.env', 2)).toBe('.env (2)')
    expect(formatBytes(512)).toBe('512 B')
    expect(formatBytes(1536)).toBe('1.5 KB')
    expect(formatBytes(50 * 1024 * 1024)).toBe('50 MB')
  })
})
