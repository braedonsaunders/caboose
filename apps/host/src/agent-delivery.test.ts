import { createHash } from 'node:crypto'
import { execFile } from 'node:child_process'
import { mkdtemp, mkdir, readFile, rm, writeFile } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { promisify } from 'node:util'
import { afterEach, describe, expect, it } from 'vitest'
import { CONFIRM_JOURNAL, emptyJournal, JOURNAL_LIMIT, MAX_OPERATIONS, PUBLISH_PROMPT, READ_DELIVERY, readJournal, readPublishedPrompt, WRITE_JOURNAL } from './agent-delivery.js'

const exec = promisify(execFile)
const roots: string[] = []
afterEach(async () => { for (const root of roots.splice(0)) await rm(root, { recursive: true, force: true }) })
const id = '11111111-1111-4111-8111-111111111111'
const deliveryId = '22222222-2222-4222-8222-222222222222'
const hash = 'a'.repeat(64)
const message = JSON.stringify({ type: 'prompt', turn: 2, deliveryId, text: 'reply' })
const reply = { id: 'key', hash, prompt: 'reply', attachments: [{ name: 'a.txt', path: `/home/caboose/Agents/${id}/attachments/files/a.txt`, bytes: 10 }] }
async function root() { const dir = await mkdtemp(join(tmpdir(), 'caboose-delivery-')); roots.push(dir); return dir }
const node = (script: string, args: string[]) => exec(process.execPath, ['-e', script, ...args])

describe('atomic durable files', () => {
  it('publishes a bounded journal whole and leaves the previous snapshot on a pre-rename failure', async () => {
    const dir = await root(), path = join(dir, 'delivery.json')
    const first = JSON.stringify(emptyJournal())
    const next = JSON.stringify({ ...emptyJournal(), operations: [{ id: 'key', hash }], queue: [reply] })
    await node(WRITE_JOURNAL, [path, first])
    const failRename = `require('node:fs/promises').rename = async () => {throw Error('rename failed')};\n`
    await expect(node(failRename + WRITE_JOURNAL, [path, next])).rejects.toThrow('rename failed')
    expect(await readFile(path, 'utf8')).toBe(first)
    await node(WRITE_JOURNAL, [path, next])
    expect(readJournal(await readFile(path, 'utf8'), id).queue[0]).toEqual(reply)
  })

  it('leaves the committed snapshot readable if the command fails after rename', async () => {
    const dir = await root(), path = join(dir, 'delivery.json')
    const text = JSON.stringify(emptyJournal())
    const failAfterRename = `const originalRename = require('node:fs/promises').rename; require('node:fs/promises').rename = async (...args) => {await originalRename(...args); throw Error('response lost')};\n`
    await expect(node(failAfterRename + WRITE_JOURNAL, [path, text])).rejects.toThrow('response lost')
    expect(await readFile(path, 'utf8')).toBe(text)
    expect((await node(CONFIRM_JOURNAL, [path, createHash('sha256').update(text).digest('hex')])).stdout.trim()).toBe('confirmed')
    await expect(node(CONFIRM_JOURNAL, [path, 'bad'])).rejects.toThrow('journal changed')
  })

  it('never republishes a consumed inbox, and returns bounded evidence including a receipt', async () => {
    const dir = await root()
    await node(PUBLISH_PROMPT, [dir, message, '000002'])
    expect(await readFile(join(dir, 'inbox/000002.prompt.json'), 'utf8')).toBe(message)
    await rm(join(dir, 'inbox/000002.prompt.json'))
    await node(PUBLISH_PROMPT, [dir, message, '000002'])
    await expect(readFile(join(dir, 'inbox/000002.prompt.json'))).rejects.toMatchObject({ code: 'ENOENT' })
    await mkdir(join(dir, 'receipts'))
    const receipt = JSON.stringify({ turn: 2, deliveryId, state: 'claimed' })
    await writeFile(join(dir, 'receipts/000002.json'), receipt)
    const evidence = JSON.parse((await node(READ_DELIVERY, [dir, '000002'])).stdout)
    expect(evidence).toMatchObject({ receipt, inbox: '', published: message, alive: false })
    await expect(node(PUBLISH_PROMPT, [dir, message.replace('reply', 'different'), '000002'])).rejects.toThrow('delivery conflict')
  })

  it('retains the publication marker when interrupted before inbox publication, without treating absence as proof', async () => {
    const dir = await root()
    const failInbox = `const originalRename = require('node:fs/promises').rename; require('node:fs/promises').rename = async (from,to) => {if(to.includes('/inbox/'))throw Error('inbox write failed');return originalRename(from,to)};\n`
    await expect(node(failInbox + PUBLISH_PROMPT, [dir, message, '000002'])).rejects.toThrow('inbox write failed')
    const evidence = JSON.parse((await node(READ_DELIVERY, [dir, '000002'])).stdout)
    expect(evidence).toMatchObject({ receipt: '', inbox: '', published: message })
    await node(PUBLISH_PROMPT, [dir, message, '000002'])
    await expect(readFile(join(dir, 'inbox/000002.prompt.json'))).rejects.toMatchObject({ code: 'ENOENT' })
  })

  it('refuses oversized stored evidence', async () => {
    const dir = await root()
    await writeFile(join(dir, 'delivery.json'), 'x'.repeat(JOURNAL_LIMIT + 1))
    await expect(node(READ_DELIVERY, [dir, ''])).rejects.toThrow('too large')
  })
})

describe('retained prompt envelopes', () => {
  const intent = { id: deliveryId, turn: 1, replies: [] }
  const envelope = () => ({ type: 'prompt', turn: 1, deliveryId, text: 'inspect these',
    attachments: [{ path: `/home/caboose/Agents/${id}/attachments/image.png`, name: 'image.png', mimeType: 'image/png' }] })

  it('accepts the original name and MIME metadata without reconstructing the envelope', () => {
    expect(readPublishedPrompt(JSON.stringify(envelope(), null, 2), id, intent)).toEqual({ text: 'inspect these' })
  })

  it.each([
    (v: any) => { v.turn = 2 },
    (v: any) => { v.deliveryId = id },
    (v: any) => { v.text = 'x'.repeat(32001) },
    (v: any) => { v.attachments[0].path = '/etc/passwd' },
    (v: any) => { v.attachments[0].path += '/../outside' },
    (v: any) => { v.attachments[0].mimeType = 'x'.repeat(256) },
    (v: any) => { v.attachments = Array(5).fill(v.attachments[0]) },
  ])('refuses an untrusted retained envelope with invalid identity or file metadata (%#)', mutate => {
    const value = envelope(); mutate(value)
    expect(() => readPublishedPrompt(JSON.stringify(value), id, intent)).toThrow()
  })
})

describe('untrusted journals', () => {
  const valid = () => ({ ...emptyJournal(), original: hash, queue: [reply], operations: [{ id: 'key', hash }], intent: { id: deliveryId, turn: 2, replies: ['key'] } })
  it('validates the exact schema and strips unrelated guest fields', () => {
    expect(readJournal(JSON.stringify({ ...valid(), injected: 'bad' }), id)).toEqual(valid())
  })
  it.each([
    (v: any) => { v.version = 2 },
    (v: any) => { v.original = 'bad' },
    (v: any) => { v.operations = Array(MAX_OPERATIONS + 1).fill(v.operations[0]) },
    (v: any) => { v.operations.push(v.operations[0]) },
    (v: any) => { v.operations[0].id = 'x'.repeat(201) },
    (v: any) => { v.queue[0].attachments[0].path = '/etc/passwd' },
    (v: any) => { v.queue[0].attachments[0].path += '/../secret' },
    (v: any) => { v.queue[0].attachments[0].bytes = 20 * 1024 * 1024 },
    (v: any) => { v.queue[0].attachments[0].name = 'x'.repeat(256) },
    (v: any) => { v.queue[0].prompt = 'x'.repeat(32001) },
    (v: any) => { v.queue[0].hash = 'b'.repeat(64) },
    (v: any) => { v.intent.turn = Infinity },
    (v: any) => { v.intent.replies = ['unknown'] },
    (v: any) => { v.intent.id = '../../bad' },
    (v: any) => { v.startAttachments = [`/home/caboose/Agents/${id}/attachments/../outside`] },
  ])('rejects invalid state instead of silently dropping durable work (%#)', mutate => {
    const v = JSON.parse(JSON.stringify(valid())); mutate(v)
    expect(() => readJournal(JSON.stringify(v), id)).toThrow()
  })
})
