import { describe, expect, it } from 'vitest'
import { AgentInputError, type AgentGuest } from './agents.js'
import { decodeBase64, openUrl, parseWebUrl, sanitizeFileName, splitName, uniqueName } from './files.js'

describe('file names', () => {
  it('keeps only a safe last path component', () => {
    expect(sanitizeFileName('../../etc/passwd')).toBe('passwd')
    expect(sanitizeFileName('C:\\Users\\me\\photo.jpg')).toBe('photo.jpg')
    expect(sanitizeFileName('.bashrc')).toBe('bashrc')
    expect(sanitizeFileName('..')).toBe('file')
    expect(sanitizeFileName('a\u0000b\nc.txt')).toBe('abc.txt')
    expect(sanitizeFileName('   ')).toBe('file')
    expect(sanitizeFileName(42)).toBe('file')
    const long = sanitizeFileName(`${'x'.repeat(300)}.png`)
    expect(long).toHaveLength(120)
    expect(long.endsWith('.png')).toBe(true)
  })

  it('splits extensions and finds the next free "name (n).ext"', () => {
    expect(splitName('report.final.pdf')).toEqual({ stem: 'report.final', ext: '.pdf' })
    expect(splitName('Makefile')).toEqual({ stem: 'Makefile', ext: '' })
    expect(uniqueName('a.txt', new Set())).toBe('a.txt')
    expect(uniqueName('a.txt', new Set(['a.txt', 'a (2).txt']))).toBe('a (3).txt')
  })

  it('decodes strict base64 only', () => {
    expect(decodeBase64('aGk=', 'data').toString()).toBe('hi')
    expect(decodeBase64('aG\nk=', 'data').toString()).toBe('hi')
    expect(() => decodeBase64('aGk', 'data')).toThrow(AgentInputError)
    expect(() => decodeBase64('a$k=', 'data')).toThrow(AgentInputError)
    expect(() => decodeBase64(7, 'data')).toThrow('data must be base64')
  })
})

describe('parseWebUrl', () => {
  it('accepts http(s) URLs only', () => {
    expect(parseWebUrl('https://example.com/a?b=c')).toBe('https://example.com/a?b=c')
    expect(parseWebUrl('http://localhost:3000')).toBe('http://localhost:3000/')
    for (const bad of ['javascript:alert(1)', 'file:///etc/passwd', 'ftp://example.com', 'https://exa mple.com', '-https://x', '', 42]) {
      expect(() => parseWebUrl(bad)).toThrow(AgentInputError)
    }
  })
})

function recordingGuest() {
  const calls: string[][] = []
  const guest: AgentGuest = { async run(command, args) { calls.push([command, ...args]); return '' } }
  return { guest, calls }
}

describe('openUrl', () => {
  it('opens on the owner display as caboose', async () => {
    const { guest, calls } = recordingGuest()
    expect(await openUrl(guest, { url: 'https://example.com' })).toEqual({ opened: true })
    expect(calls[0]?.slice(0, 3)).toEqual(['/usr/sbin/runuser', '-u', 'caboose'])
    expect(calls[0]?.at(-1)).toBe('https://example.com/')
    await expect(openUrl(guest, { url: 'file:///etc/shadow' })).rejects.toBeInstanceOf(AgentInputError)
  })
})
