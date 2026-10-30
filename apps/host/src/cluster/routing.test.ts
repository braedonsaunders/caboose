import { expect, it, vi } from 'vitest'
import { mkdtemp, rm } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { once } from 'node:events'
import type { AddressInfo } from 'node:net'
import { ComputerRegistry, PhoneTokens } from '../computers.js'
import { createCabooseServer, type Controller } from '../server.js'
import { SettingsStore, settingsLimits } from '../settings.js'
import type { ClusterRuntime } from './runtime.js'
import { OwnershipError } from './coordinator.js'

it('refuses stale execution routes while exposing location only to authorized identities', async () => {
  const root = await mkdtemp(join(tmpdir(),'cluster-routes-'))
  const computers = await ComputerRegistry.open(root), phones = PhoneTokens.memory()
  const phone = await phones.mint('owner','phone')
  const settings = new SettingsStore({name:'Test',defaultAgent:null,memoryMb:512,vcpus:1,idleMs:30000},settingsLimits(),{load:async()=>undefined,save:async()=>{}})
  const wake = vi.fn()
  const controller = {wake,park:async()=>{},stats:()=>({}),activeResources:()=>null,hasSavedState:()=>false,guest:()=>undefined,apps:async()=>[],launch:async()=>{},ensureAgentSeat:async()=>{},displayUrl:'ws://localhost',agentDisplayUrl:'ws://localhost'} as unknown as Controller
  let revoked = false
  const cluster = {
    coordinator:{assertHost:async()=>{if(revoked)throw new OwnershipError('revoked')},lookup:async()=>({generation:'2',host_id:'b',expired:false}),pool:{query:async()=>({rows:[{endpoint:'https://b.example.invalid'}]})}},
    authorize:async()=>{throw new OwnershipError('Computer is owned by https://b.example.invalid')},
  } as unknown as ClusterRuntime
  const pieces = {settings,controller}
  const app = createCabooseServer({token:'operator',...pieces,cluster,fleet:{computers,phones,maxRunning:4,defaults:{memoryMb:512,vcpus:1,idleMs:30000},open:async()=>pieces}})
  try {
    app.server.listen(0,'127.0.0.1'); await once(app.server,'listening')
    const base=`http://127.0.0.1:${(app.server.address() as AddressInfo).port}`
    const request=(path:string,token=phone.token,method='GET')=>fetch(base+path,{method,headers:{authorization:`Bearer ${token}`}})
    expect((await request('/v1/session',phone.token,'POST')).status).toBe(409)
    expect(wake).not.toHaveBeenCalled()
    expect(await (await request('/v1/location')).json()).toMatchObject({computerId:'owner',generation:'2',endpoint:'https://b.example.invalid'})
    expect((await request('/v1/computers/c-1234567890/location')).status).toBe(404)
    expect((await request('/v1/computers/owner/cluster/recover',phone.token,'POST')).status).toBe(403)
    await phones.revoke('owner',phone.phone.id)
    expect((await request('/v1/location')).status).toBe(401)
    revoked=true
    expect((await request('/v1/location','operator')).status).toBe(409)
  } finally {await app.shutdown(); await rm(root,{recursive:true,force:true})}
})

it('keeps unrelated HTTP work concurrent while checkpoint cancels and drains only its computer', async () => {
  const { request: httpRequest } = await import('node:http')
  function deferred() { let resolve!: () => void; const promise = new Promise<void>(done => { resolve = done }); return { promise, resolve } }
  const saving = deferred(), allowSave = deferred(), capturing = deferred(), allowCapture = deferred()
  const root = await mkdtemp(join(tmpdir(), 'cluster-admission-'))
  const computers = await ComputerRegistry.open(root), phones = PhoneTokens.memory()
  const other = await computers.create()
  let heldSave = true
  const settingsFor = (id: string) => new SettingsStore({ name:'Before',defaultAgent:null,memoryMb:512,vcpus:1,idleMs:30000 },settingsLimits(), {
    load:async()=>undefined, save:async()=>{ if (id === 'owner' && heldSave) { saving.resolve(); await allowSave.promise } },
  })
  const ownerSettings = settingsFor('owner'), otherSettings = settingsFor(other.id)
  const controller = { wake:vi.fn(),park:async()=>{},stats:()=>({}),activeResources:()=>null,hasSavedState:()=>false,guest:()=>undefined,apps:async()=>[],launch:async()=>{},ensureAgentSeat:async()=>{},displayUrl:'ws://localhost',agentDisplayUrl:'ws://localhost' } as unknown as Controller
  const pieces = (id: string) => ({ settings:id === 'owner' ? ownerSettings : otherSettings,controller })
  const capture = vi.fn(async () => { capturing.resolve(); await allowCapture.promise; return { version:1 } })
  const cluster = {
    coordinator:{assertHost:async()=>{},lookup:async()=>({generation:'1',host_id:'a',expired:false}),pool:{query:async()=>({rows:[{endpoint:'https://a.example.invalid'}]})}},
    authorize:async()=>{},roots:new Map([['owner',root]]),root,owned:new Map([['owner',{generation:'1'}]]),recovery:{capture},
  } as unknown as ClusterRuntime
  const app = createCabooseServer({ token:'operator',...pieces('owner'),cluster,fleet:{ computers,phones,maxRunning:4,defaults:{memoryMb:512,vcpus:1,idleMs:30000},open:async record=>pieces(record.id),existing:[{record:other,pieces:pieces(other.id)}] } })
  let slowPair: ReturnType<typeof httpRequest> | undefined
  let mutation: Promise<unknown> | undefined, checkpoint: Promise<Response> | undefined
  try {
    app.server.listen(0,'127.0.0.1'); await once(app.server,'listening')
    const base=`http://127.0.0.1:${(app.server.address() as AddressInfo).port}`
    const request=(path:string,method='GET',body?:string)=>fetch(base+path,{method,body,signal:AbortSignal.timeout(2000),headers:{authorization:'Bearer operator','content-type':'application/json'}})
    // Unauthenticated, incomplete body: must never acquire a host-wide queue slot.
    slowPair=httpRequest(base+'/v1/pair',{method:'POST',headers:{'content-type':'application/json','content-length':100}})
    slowPair.on('error',()=>{}); slowPair.write('{')
    expect((await request('/v1/location')).status).toBe(200)
    expect((await request(`/v1/computers/${other.id}/computer`)).status).toBe(200)
    mutation=request('/v1/computer/settings','PATCH',JSON.stringify({name:'Written before capture'})).catch(()=>undefined)
    await saving.promise
    checkpoint=request('/v1/computers/owner/cluster/checkpoint','POST')
    // A cancelled transport is not enough: capture must wait for the actual save.
    expect((await request(`/v1/computers/${other.id}/computer/settings`,'PATCH',JSON.stringify({name:'Independent'}))).status).toBe(200)
    expect(capture).not.toHaveBeenCalled()
    heldSave=false; allowSave.resolve()
    await capturing.promise
    expect(ownerSettings.get().name).toBe('Written before capture')
    expect((await request('/v1/computer/settings','PATCH',JSON.stringify({name:'Must not write'}))).status).toBe(409)
    expect((await request('/v1/location')).status).toBe(200)
    expect((await request(`/v1/computers/${other.id}/computer`)).status).toBe(200)
    allowCapture.resolve()
    expect((await checkpoint).status).toBe(201)
    expect(ownerSettings.get().name).toBe('Written before capture')
    expect((await request('/v1/computer/settings','PATCH',JSON.stringify({name:'After'}))).status).toBe(200)
  } finally {
    heldSave=false; allowSave.resolve(); allowCapture.resolve(); slowPair?.destroy()
    await mutation; await checkpoint?.catch(()=>{})
    await app.shutdown(); await rm(root,{recursive:true,force:true})
  }
})
