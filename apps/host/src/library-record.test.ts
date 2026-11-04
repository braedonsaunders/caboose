import { mkdtempSync, readFileSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { describe, expect, it } from 'vitest'
import { LibraryRecord, parseRecord } from './library-record.js'

const debian = { name: 'Mousepad', summary: 'Text editor', desktopId: 'org.xfce.mousepad.desktop', package: 'mousepad', componentId: 'org.xfce.mousepad', license: null }

describe('Library record', () => {
  it('is written whole, survives a new host process and starts empty without a file', async () => {
    const file = join(mkdtempSync(join(tmpdir(), 'caboose-record-')), 'computer', 'library-apps.json')
    const record = new LibraryRecord(file)
    expect(await record.list()).toEqual([])
    expect(await record.add({ id: 'gimp' })).toBe(true)
    expect(await record.add({ id: 'gimp' })).toBe(false)
    await record.add({ id: 'debian-mousepad', debian })
    await record.remove('gimp')
    expect(JSON.parse(readFileSync(file, 'utf8'))).toEqual({ apps: [{ id: 'debian-mousepad', debian }] })
    expect(await new LibraryRecord(file).list()).toEqual([{ id: 'debian-mousepad', debian }])
  })

  it('leaves out anything malformed', () => {
    expect(parseRecord('not json')).toEqual([])
    expect(parseRecord(JSON.stringify({ apps: [{ id: 'gimp' }, { id: '../etc' }, { id: 'debian-x', debian: { ...debian, package: 'Bad Name' } }, 7, { id: 'gimp' }] }))).toEqual([{ id: 'gimp' }])
  })

  it('keeps reading a file another host version wrote with extra fields', async () => {
    const file = join(mkdtempSync(join(tmpdir(), 'caboose-record-')), 'library-apps.json')
    writeFileSync(file, JSON.stringify({ apps: [{ id: 'krita', note: 'x' }] }))
    expect(await new LibraryRecord(file).list()).toEqual([{ id: 'krita' }])
  })
})
