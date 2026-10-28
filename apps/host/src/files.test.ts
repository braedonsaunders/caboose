import { describe, expect, it } from 'vitest'
import { AgentInputError, type AgentGuest } from './agents.js'
import { decodeBase64, openUrl, parseWebUrl, sanitizeFileName, saveDownload, splitName, uniqueName } from './files.js'

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

/** Records each guest command and rebuilds files from the chunked writes. */
function recordingGuest(existing: string[] = []) {
  const calls: string[][] = []
  const files = new Map<string, Buffer>()
  const guest: AgentGuest = {
    async run(command, args) {
      calls.push([command, ...args])
      const script = args[5] ?? ''
      const rest = args.slice(7)
      if (script.includes(': > "$1"')) files.set(rest[0]!, Buffer.alloc(0))
      if (script.includes('base64 -d')) files.set(rest[0]!, Buffer.concat([files.get(rest[0]!)!, Buffer.from(rest.slice(1).join(''), 'base64')]))
      if (script.includes('while [ -e "$target" ]')) {
        const [dir, part, name, stem, ext] = rest as [string, string, string, string, string]
        let target = name
        for (let n = 2; existing.includes(target); n++) target = `${stem} (${n})${ext}`
        files.set(`${dir}/${target}`, files.get(part)!)
        files.delete(part)
        return `${dir}/${target}`
      }
      return ''
    },
  }
  return { guest, calls, files }
}

describe('saveDownload', () => {
  it('writes in argument-sized chunks as caboose and de-duplicates the name', async () => {
    const { guest, calls, files } = recordingGuest(['notes.txt'])
    const data = Buffer.alloc(2_000_000)
    for (let i = 0; i < data.length; i++) data[i] = i % 251
    const { path } = await saveDownload(guest, { name: '../notes.txt', data: data.toString('base64') })
    expect(path).toBe('/home/caboose/Downloads/notes (2).txt')
    expect(files.get(path)?.equals(data)).toBe(true)
    expect(calls.every(call => call[0] === '/usr/sbin/runuser' && call[2] === 'caboose')).toBe(true)
    const writes = calls.filter(call => call[6]?.includes('base64 -d'))
    expect(writes.length).toBeGreaterThan(2)
    for (const write of writes) {
      expect(write.slice(9).every(chunk => chunk.length <= 96 * 1024)).toBe(true)
      expect(write.slice(9).join('').length).toBeLessThanOrEqual(8 * 96 * 1024)
    }
    expect(calls.some(call => call.some(arg => arg.includes('xdg-open')))).toBe(false)
  })

  it('opens the saved file on the owner display when asked', async () => {
    const { guest, calls } = recordingGuest()
    await saveDownload(guest, { name: 'a.pdf', data: 'aGk=', open: true })
    const open = calls.at(-1)!
    expect(open.slice(4, 7)).toEqual(['/usr/bin/env', 'DISPLAY=:100', '/bin/sh'])
    expect(open[8]).toContain('xdg-open')
    expect(open.at(-1)).toBe('/home/caboose/Downloads/a.pdf')
  })

  it('opens on Caboose Display with the launch environment the computer reports', async () => {
    const { guest, calls } = recordingGuest()
    const env = ['WAYLAND_DISPLAY=wayland-caboose-0', 'XDG_RUNTIME_DIR=/run/user/1000', 'DISPLAY=:110', 'GDK_BACKEND=wayland,x11']
    await openUrl({ ...guest, ownerEnv: env }, { url: 'https://example.com/' })
    expect(calls.at(-1)!.slice(4, 10)).toEqual(['/usr/bin/env', ...env, '/bin/sh'])
    expect(calls.at(-1)!.join(' ')).not.toContain(':100')
  })

  it('validates before touching the guest', async () => {
    const { guest, calls } = recordingGuest()
    await expect(saveDownload(guest, { name: '', data: 'aGk=' })).rejects.toThrow('name is required')
    await expect(saveDownload(guest, { name: 'a', data: '***' })).rejects.toBeInstanceOf(AgentInputError)
    await expect(saveDownload(guest, { name: 'a', data: 'aGk=', open: 'yes' })).rejects.toBeInstanceOf(AgentInputError)
    await expect(saveDownload(guest, { name: 'a', data: Buffer.alloc(50 * 1024 * 1024 + 1).toString('base64') })).rejects.toThrow('50 MB')
    await expect(saveDownload(undefined, { name: 'a', data: 'aGk=' })).rejects.toThrow('computer is not running')
    expect(calls).toEqual([])
  })
})

describe('openUrl', () => {
  it('opens on the owner display as caboose', async () => {
    const { guest, calls } = recordingGuest()
    expect(await openUrl(guest, { url: 'https://example.com' })).toEqual({ opened: true })
    expect(calls[0]?.slice(0, 3)).toEqual(['/usr/sbin/runuser', '-u', 'caboose'])
    expect(calls[0]?.at(-1)).toBe('https://example.com/')
    await expect(openUrl(guest, { url: 'file:///etc/shadow' })).rejects.toBeInstanceOf(AgentInputError)
  })
})
