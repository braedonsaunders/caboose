import { expect, it, vi } from 'vitest'
import * as fs from 'node:fs/promises'
vi.mock('node:fs/promises', async importOriginal => ({ ...await importOriginal<typeof import('node:fs/promises')>() }))
import { join } from 'node:path'
import { tmpdir } from 'node:os'
import { randomBytes } from 'node:crypto'
import { Readable } from 'node:stream'
import { Recovery } from './recovery.js'
import type { Coordinator, Ownership } from './coordinator.js'
import { PortableComputerStore } from '../portable-storage/index.js'
import type { SnapshotObjectStore } from '../snapshot-archive.js'
import { CommandStore, type CommandRecord } from '../commands.js'
import { ComputerLifecycle } from '../lifecycle.js'

it('captures drained receipts and activates restored history only after modified directory entries are durable', async () => {
  const root = await fs.mkdtemp(join(tmpdir(),'receipt-recovery-'))
  const source=join(root,'source'), target=join(root,'target')
  const objects=new Map<string,Buffer>()
  const store: SnapshotObjectStore={
    putStream:async ({key,body})=>{const chunks:Buffer[]=[];for await(const chunk of body)chunks.push(Buffer.from(chunk));objects.set(key,Buffer.concat(chunks))},
    getStream:async key=>({stream:Readable.toWeb(Readable.from([objects.get(key)!])) as ReadableStream}),delete:async key=>{objects.delete(key)},
  }
  const compatibility={runtime:'linux-microvm' as const,architecture:'x64' as const,runtimeVersion:'receipt-test'}
  const archives=new PortableComputerStore(store,randomBytes(32))
  let row:Ownership={id:'owner',generation:'1',host_id:'source',checkpoint:null,compatibility:JSON.stringify(compatibility),expired:false}
  const release=vi.fn(async()=>{row={...row,host_id:null}})
  const coordinator={ttlMs:30000,assertOwner:async()=>{},renew:async()=>{},lookup:async()=>row,
    publish:async (_id:string,_generation:string,checkpoint:unknown)=>{row={...row,checkpoint}},
    claim:async()=>{row={...row,generation:String(Number(row.generation)+1),host_id:'target'};return row},release,
  } as unknown as Coordinator
  const fence={fence:vi.fn()}
  const capture=new Recovery(coordinator,archives,compatibility,source,fence), recovery=new Recovery(coordinator,archives,compatibility,target,fence)
  const record:CommandRecord={id:'3'.repeat(32),title:'finished',script:'echo done',cwd:null,inputs:[],timeout:30,status:'succeeded',exitCode:0,signal:null,error:null,stdout:'receipt output',stderr:'',truncated:{stdout:false,stderr:false},outputs:[],createdAt:new Date().toISOString(),finishedAt:new Date().toISOString()}
  const originalOpen=fs.open
  let openSpy: { mockRestore(): void } | undefined
  try {
    await fs.mkdir(join(source,'overlays'),{recursive:true});await fs.mkdir(target)
    for(const name of ['vmlinux','initrd','keyring-secret'])await fs.writeFile(join(source,name),name==='keyring-secret'?'ab'.repeat(32):name)
    await fs.writeFile(join(source,'overlays','owner.raw'),'disk fixture');await fs.writeFile(join(target,'base.raw'),'base')
    const commands=await CommandStore.open(join(source,'commands'));await commands.save(record);await commands.drain()
    const lifecycle=new ComputerLifecycle({wake:async()=>({}),park:async()=>{}},1000)
    await capture.capture(row,{id:'owner',slot:0,createdAt:null,tenantId:null,person:null},{name:'Computer',defaultAgent:null,memoryMb:512,vcpus:1,idleMs:1000},lifecycle,source,source)
    await fs.rm(source,{recursive:true});row={...row,host_id:null}
    // A failed sync of renamed disk entries must prevent a complete activation marker.
    openSpy=vi.spyOn(fs,'open').mockImplementation(async (...args:Parameters<typeof fs.open>)=>{
      const handle=await originalOpen(...args)
      if(String(args[0]).endsWith('.restoring/overlays'))handle.sync=async()=>{throw new Error('directory durability failure')}
      return handle
    })
    await expect(recovery.recover('owner')).rejects.toThrow('directory durability failure')
    expect(await recovery.activated({...row,generation:'2'})).toBeUndefined()
    expect(release).toHaveBeenCalledOnce()
    openSpy.mockRestore();openSpy=undefined
    const restored=await recovery.recover('owner')
    const directory=await recovery.activated(restored)
    expect(restored.generation).toBe('3')
    const restoredCommands=await CommandStore.open(join(directory!,'commands'))
    expect(restoredCommands.get(record.id)).toEqual(record)
    expect(await fs.readFile(join(directory!,'overlays','owner.raw'),'utf8')).toBe('disk fixture')
    expect((await fs.readdir(directory!)).some(name=>name.startsWith('command-'))).toBe(false)
    expect(fence.fence).not.toHaveBeenCalled()
  } finally {openSpy?.mockRestore();await fs.rm(root,{recursive:true,force:true})}
})
