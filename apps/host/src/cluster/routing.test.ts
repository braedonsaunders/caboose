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
