import { mkdtemp, readFile, rm, writeFile } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { expect, it } from 'vitest'
import { ParkedFilesJournal } from './parked-files-journal.js'

it('persists an exclusive recovery intent until its matching thaw is confirmed', async () => {
  const root = await mkdtemp(join(tmpdir(), 'parked-files-'))
  try {
    const file = join(root, 'intent')
    const journal = new ParkedFilesJournal(file)
    const intent = await journal.begin()
    expect(await new ParkedFilesJournal(file).read()).toEqual(intent)
    await expect(journal.begin()).rejects.toMatchObject({ code: 'EEXIST' })
    await expect(journal.clear('wrong')).rejects.toThrow('changed')
    expect(await readFile(file, 'utf8')).toContain(intent.id)
    await journal.clear(intent.id)
    expect(await journal.read()).toBeUndefined()
  } finally { await rm(root, { recursive: true, force: true }) }
})

it('fails closed on corrupt recovery metadata', async () => {
  const root = await mkdtemp(join(tmpdir(), 'parked-files-'))
  try {
    const file = join(root, 'intent')
    await writeFile(file, '{broken')
    const journal = new ParkedFilesJournal(file)
    await expect(journal.read()).rejects.toThrow('Invalid parked Files recovery intent')
    await expect(journal.clear('x')).rejects.toThrow('Invalid parked Files recovery intent')
  } finally { await rm(root, { recursive: true, force: true }) }
})

it('persists exact branch state and rejects overlapping or unsafe paths', async () => {
  const root = await mkdtemp(join(tmpdir(), 'parked-files-'))
  try {
    const journal = new ParkedFilesJournal(join(root, 'intent'))
    for (const branches of [[{ path: '/a/../b', frozen: false }], [{ path: '/a', frozen: false }, { path: '/a/b', frozen: true }]]) {
      await expect(journal.begin(branches)).rejects.toThrow('Invalid')
    }
    const branches = [{ path: '/system.slice/a.service', frozen: false }, { path: '/user.slice', frozen: true }]
    await expect(journal.begin(branches, -1)).rejects.toThrow('Invalid')
    const intent = await journal.begin(branches, 64769)
    expect(await journal.read()).toEqual({ version: 2, id: intent.id, branches, homeDevice: 64769 })
    await journal.clear(intent.id)
  } finally { await rm(root, { recursive: true, force: true }) }
})
