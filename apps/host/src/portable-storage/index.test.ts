import { createHash, randomBytes } from 'node:crypto'
import { mkdtemp, mkdir, writeFile, readFile, rm, readdir } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { Readable } from 'node:stream'
import { afterEach, expect, it } from 'vitest'
import { PortableComputerStore, type PortableSource } from './index.js'
import type { SnapshotObjectStore } from '../snapshot-archive.js'
const roots: string[] = []
afterEach(async () => { for (const root of roots.splice(0)) await rm(root, { recursive: true, force: true }) })
async function setup() {
  const root = await mkdtemp(join(tmpdir(), 'portable-')); roots.push(root)
  const directory = join(root, 'source'); await mkdir(directory)
  for (const name of ['disk.raw', 'vmlinux', 'initrd', 'keyring-secret']) await writeFile(join(directory, name), name === 'keyring-secret' ? 'ab'.repeat(32) : `private ${name}`)
  await writeFile(join(directory, 'computer.json'), JSON.stringify({ version: 1, record: { id: 'owner', slot: 0 }, settings: { name: 'Computer' } }))
  const objects = new Map<string, Buffer>()
  const store: SnapshotObjectStore = {
    async putStream({ key, body }) { const chunks: Buffer[] = []; for await (const chunk of body) chunks.push(Buffer.from(chunk)); objects.set(key, Buffer.concat(chunks)) },
    async getStream(key) { if (!objects.has(key)) throw new Error('missing'); return { stream: Readable.toWeb(Readable.from([objects.get(key)!])) as ReadableStream } },
    async delete(key) { objects.delete(key) },
  }
  const source: PortableSource = { directory, metadata: { computerId: 'owner', runtime: 'linux-microvm', architecture: 'x64', runtimeVersion: 'test-1', imageFormat: 'monolithic', createdAt: new Date().toISOString() } }
  const key = randomBytes(32), archives = new PortableComputerStore(store, key)
  const authority = { withCapture: async <T>(work: (s: PortableSource) => Promise<T>) => work(source) }
  return { root, source, objects, store, key, archives, authority }
}
it('round trips full disk, boot assets, credentials and metadata across independent store instances', async () => {
  const s = await setup(); const ref = await s.archives.capture(s.authority, join(s.root, 'receipt'))
  expect([...s.objects.values()].some(data => data.includes('private'))).toBe(false)
  const target = join(s.root, 'restored')
  await new PortableComputerStore(s.store, s.key).restore(ref, s.source.metadata, target)
  for (const name of await readdir(s.source.directory)) expect(await readFile(join(target, name))).toEqual(await readFile(join(s.source.directory, name)))
  await expect(s.archives.restore(ref, s.source.metadata, target)).rejects.toThrow()
  expect(await readFile(join(target, 'disk.raw'), 'utf8')).toBe('private disk.raw')
})
it('rejects wrong keys, incompatible runtime, tampered manifests and damaged payloads without publishing a restore', async () => {
  const s = await setup(); const ref = await s.archives.capture(s.authority, join(s.root, 'receipt'))
  await expect(new PortableComputerStore(s.store, randomBytes(32)).inspect(ref, s.source.metadata)).rejects.toThrow('key')
  await expect(s.archives.inspect(ref, { ...s.source.metadata, architecture: 'arm64' })).rejects.toThrow('Incompatible')
  const manifest = await s.archives.inspect(ref, s.source.metadata)
  const payload = manifest.archive.entries[0]!.key; s.objects.get(payload)![0]! ^= 1
  const target = join(s.root, 'restored')
  await expect(s.archives.restore(ref, s.source.metadata, target)).rejects.toThrow()
  await expect(readdir(target)).rejects.toThrow()
  s.objects.get(ref.key)![30]! ^= 1
  await expect(s.archives.inspect(ref, s.source.metadata)).rejects.toThrow()
})
it('requires controller admission and complete independent boot inputs', async () => {
  const s = await setup()
  await expect(s.archives.capture({ withCapture: async () => { throw new Error('active') } }, join(s.root, 'active'))).rejects.toThrow('active')
  expect(s.objects.size).toBe(0)
  s.source.metadata.imageFormat = 'split'
  await expect(s.archives.capture(s.authority, join(s.root, 'split'))).rejects.toThrow('Incomplete')
  expect(s.objects.size).toBe(0)
})
it('journals interrupted PUTs and reconciles cleanup; never cleans a potentially committed publication', async () => {
  const s = await setup(); const put = s.store.putStream
  s.store.putStream = async input => { await put(input); throw new Error('lost response') }
  const receipt = join(s.root, 'receipt')
  await expect(s.archives.capture(s.authority, receipt)).rejects.toThrow('lost response')
  await s.archives.discardInterrupted(receipt); expect(s.objects.size).toBe(0)
  s.store.putStream = async input => { await put(input); if (input.key.endsWith('/manifest')) throw new Error('lost commit response') }
  await expect(s.archives.capture(s.authority, receipt)).rejects.toThrow('lost commit')
  const journal = JSON.parse(await readFile(receipt, 'utf8'))
  await expect(s.archives.discardInterrupted(receipt)).rejects.toThrow('may be committed')
  await s.archives.restore(journal.ref, s.source.metadata, join(s.root, 'recovered'))
})
it('cancels before publication and refuses symlink inputs', async () => {
  const s = await setup(); const abort = new AbortController(); abort.abort()
  await expect(s.archives.capture(s.authority, join(s.root, 'receipt'), abort.signal)).rejects.toThrow()
  expect(s.objects.size).toBe(0)
  const { symlink } = await import('node:fs/promises')
  await rm(join(s.source.directory, 'disk.raw')); await symlink(join(s.source.directory, 'vmlinux'), join(s.source.directory, 'disk.raw'))
  await expect(s.archives.capture(s.authority, join(s.root, 'link'))).rejects.toThrow('unsupported')
})
it('preserves sparse disk length, split boot assets and per-computer profile state', async () => {
  const s = await setup(); s.source.metadata.imageFormat = 'split'
  const { open } = await import('node:fs/promises')
  const file = await open(join(s.source.directory, 'disk.raw'), 'r+')
  await file.truncate(8 * 1024 * 1024); await file.close()
  await writeFile(join(s.source.directory, 'system.erofs'), 'immutable system')
  await writeFile(join(s.source.directory, 'agent-profiles.json'), '{"profiles":[]}')
  const ref = await s.archives.capture(s.authority, join(s.root, 'receipt'))
  const manifest = await s.archives.restore(ref, s.source.metadata, join(s.root, 'restored'))
  expect(manifest.archive.entries.find(entry => entry.name === 'disk.raw')!.size).toBe(8 * 1024 * 1024)
  expect(createHash('sha256').update(await readFile(join(s.root, 'restored', 'disk.raw'))).digest('hex')).toBe(createHash('sha256').update(await readFile(join(s.source.directory, 'disk.raw'))).digest('hex'))
  expect(await readFile(join(s.root, 'restored', 'agent-profiles.json'), 'utf8')).toBe('{"profiles":[]}')
})
it('refuses receipt reuse and malformed required state before writing objects', async () => {
  const s = await setup(); const receipt = join(s.root, 'receipt')
  await writeFile(receipt, 'existing operation')
  await expect(s.archives.capture(s.authority, receipt)).rejects.toMatchObject({ code: 'EEXIST' })
  expect(await readFile(receipt, 'utf8')).toBe('existing operation')
  await writeFile(join(s.source.directory, 'computer.json'), JSON.stringify({ version: 1, record: { id: 'c-1234567890', slot: 0 }, settings: {} }))
  await expect(s.archives.capture(s.authority, join(s.root, 'bad-state'))).rejects.toThrow('computer state')
  expect(s.objects.size).toBe(0)
})

function commandReceipt(id = '1'.repeat(32)) {
  return { id,title:'echo preserved',script:'echo preserved',cwd:null,inputs:[],timeout:30,status:'succeeded',exitCode:0,signal:null,error:null,stdout:'preserved output',stderr:'',truncated:{stdout:false,stderr:false},outputs:[],createdAt:new Date().toISOString(),finishedAt:new Date().toISOString() }
}

it('archives completed command receipts, installs them before activation, and refuses replay of restored IDs', async () => {
  const { stageCommandReceipts, installCommandReceipts } = await import('./command-receipts.js')
  const { CommandStore, ComputerCommands, parseCommandRequest } = await import('../commands.js')
  const s = await setup(), record = commandReceipt()
  const data = join(s.root,'state'); await mkdir(join(data,'commands'),{recursive:true})
  const local = await CommandStore.open(join(data,'commands'))
  await local.save(record as import('../commands.js').CommandRecord); await local.drain()
  await stageCommandReceipts(data,s.source.directory)
  const ref = await s.archives.capture(s.authority,join(s.root,'receipt'))
  await rm(data,{recursive:true}); await rm(s.source.directory,{recursive:true})
  const restored = join(s.root,'restored')
  await s.archives.restore(ref,s.source.metadata,restored)
  await installCommandReceipts(restored)
  const store = await CommandStore.open(join(restored,'commands'))
  expect(store.get(record.id)).toEqual(record)
  let wakes=0
  const commands = new ComputerCommands(store,{guest:()=>undefined,writeFile:async()=>{},acquire:()=>()=>{},wake:async()=>{wakes++},progress:()=>{}})
  commands.recover(); expect(wakes).toBe(0)
  await expect(commands.start(parseCommandRequest({id:record.id,script:'must not replay'}))).rejects.toThrow('already exists')
})

it('refuses active, mismatched, oversized and malformed receipts before publishing any objects', async () => {
  const { maxCommandReceiptBytes } = await import('./command-receipts.js')
  const { open } = await import('node:fs/promises')
  const s=await setup(), record=commandReceipt(), path=join(s.source.directory,`command-${record.id}.json`)
  let index=0
  for (const changed of [{...record,status:'running'}, {...record,id:'2'.repeat(32)}, {...record,inputs:['../escape']}, {...record,exitCode:999}, {...record,unexpected:'field'}]) {
    await writeFile(path,JSON.stringify(changed))
    await expect(s.archives.capture(s.authority,join(s.root,`receipt-${index++}`))).rejects.toThrow()
    expect(s.objects.size).toBe(0)
  }
  const file=await open(path,'w');await file.truncate(maxCommandReceiptBytes+1);await file.close()
  await expect(s.archives.capture(s.authority,join(s.root,'oversize'))).rejects.toThrow('receipt file')
})

it('refuses unsupported command directory entries and receipt symlinks instead of silently dropping history', async () => {
  const { stageCommandReceipts }=await import('./command-receipts.js')
  const { symlink }=await import('node:fs/promises')
  const s=await setup(), data=join(s.root,'state'), id='1'.repeat(32)
  await mkdir(join(data,'commands'),{recursive:true})
  await symlink(join(s.source.directory,'computer.json'),join(data,'commands',`${id}.json`))
  await expect(stageCommandReceipts(data,s.source.directory)).rejects.toThrow('Unsupported')
  await symlink(join(s.source.directory,'computer.json'),join(s.source.directory,`command-${id}.json`))
  await expect(s.archives.capture(s.authority,join(s.root,'receipt'))).rejects.toThrow()
})

it('rejects an authenticated archive carrying invalid command state on restore, removing the destination', async () => {
  const { uploadSnapshotArchive }=await import('../snapshot-archive.js')
  const { createCipheriv,randomUUID }=await import('node:crypto')
  const s=await setup(), record=commandReceipt()
  await writeFile(join(s.source.directory,`command-${record.id}.json`),JSON.stringify({...record,status:'running'}))
  // Simulate an independently produced, correctly encrypted but semantically invalid checkpoint.
  const archive=await uploadSnapshotArchive(s.source.directory,s.store,s.key)
  const id=randomUUID(), key=`computers/${id}/manifest`,nonce=randomBytes(12),cipher=createCipheriv('aes-256-gcm',s.key,nonce)
  cipher.setAAD(Buffer.from(key))
  const body=Buffer.concat([cipher.update(JSON.stringify({version:1,metadata:s.source.metadata,archive})),cipher.final()])
  s.objects.set(key,Buffer.concat([nonce,cipher.getAuthTag(),body]))
  const ref={version:1 as const,id,key,keyId:s.archives.keyId},destination=join(s.root,'invalid')
  await expect(s.archives.restore(ref,s.source.metadata,destination)).rejects.toThrow('active command receipt')
  await expect(readdir(destination)).rejects.toThrow()
})

it('fits the retained 50-command history alongside all optional state and rejects excess receipts', async () => {
  const s=await setup()
  for(const name of ['caboose.json','agent-profiles.json','mcp-library.json','agent-tool-receipts.json','agent-routines.json','push-devices.json','activities.json'])await writeFile(join(s.source.directory,name),'{}')
  for(let index=0;index<50;index++) {
    const record=commandReceipt(index.toString(16).padStart(32,'0'))
    await writeFile(join(s.source.directory,`command-${record.id}.json`),JSON.stringify(record))
  }
  const ref=await s.archives.capture(s.authority,join(s.root,'full-history'))
  const manifest=await s.archives.restore(ref,s.source.metadata,join(s.root,'restored'))
  expect(manifest.archive.entries).toHaveLength(62)
  const excess=commandReceipt('f'.repeat(32))
  await writeFile(join(s.source.directory,`command-${excess.id}.json`),JSON.stringify(excess))
  await expect(s.archives.capture(s.authority,join(s.root,'too-many'))).rejects.toThrow('unsupported')
})
