import { afterAll, beforeAll, beforeEach, describe, expect, it, vi } from 'vitest'
import pg from 'pg'
import { Coordinator, type Host } from './coordinator.js'
import { ExecutionGuard } from './guard.js'
import { AzureFence } from './azure.js'
import { execFile } from 'node:child_process'
import { promisify } from 'node:util'

const run = promisify(execFile)
const url = process.env.CABOOSE_TEST_CLUSTER_DATABASE_URL
const host = (id: string): Host => ({ id, resource: `/subscriptions/00000000-0000-0000-0000-000000000000/resourcegroups/test/providers/microsoft.compute/virtualmachines/${id}`, compatibility: 'test-v1', endpoint: `https://${id}.example.invalid` })
describe.skipIf(!url)('real PostgreSQL ownership', () => {
  const pool = new pg.Pool({ connectionString: url, max: 4, connectionTimeoutMillis: 2000, query_timeout: 3000 })
  let a: Coordinator, b: Coordinator
  beforeAll(async () => { a = new Coordinator(pool, host('a'), 1000); b = new Coordinator(pool, host('b'), 1000); await a.initialize() })
  beforeEach(async () => { await pool.query('TRUNCATE caboose_cluster_computers,caboose_cluster_hosts'); await a.initialize(); await b.initialize(); await a.enroll('owner') })
  afterAll(() => pool.end())
  it('serializes claims from two independent Node processes', async () => {
    const source = `import pg from 'pg'; import {Coordinator} from './src/cluster/coordinator.ts'; const p=new pg.Pool({connectionString:process.env.CABOOSE_TEST_CLUSTER_DATABASE_URL}); try {const h=JSON.parse(process.argv[1]); const c=new Coordinator(p,h,1000); try {const r=await c.claim('owner'); console.log(r.generation)}catch{console.log('refused')}}finally{await p.end()}`
    const results = await Promise.all(['a','b'].map(id => run(process.execPath, ['--import','tsx','--input-type=module','-e',source,JSON.stringify(host(id))])))
    expect(results.map(r => r.stdout.trim()).sort()).toEqual(['1','refused'])
  })
  it('never treats expiration as fencing proof and rejects stale renewal/release', async () => {
    const row = await a.claim('owner')
    await pool.query("UPDATE caboose_cluster_computers SET expires_at=clock_timestamp()-interval '1 second'")
    await expect(b.claim('owner')).rejects.toThrow('execution owner')
    await expect(a.renew('owner', row.generation)).rejects.toThrow()
    await expect(a.release('owner', row.generation)).rejects.toThrow()
    await expect(b.recover('owner', { fence: vi.fn() })).rejects.toThrow('checkpoint')
  })
  it('permanently revokes a source on failed fence and increments generation only after proof', async () => {
    const row = await a.claim('owner'); await a.publish('owner', row.generation, { verified: true })
    await pool.query("UPDATE caboose_cluster_computers SET expires_at=clock_timestamp()-interval '1 second'")
    await expect(b.recover('owner', { fence: async () => { throw new Error('provider partition') } })).rejects.toThrow('provider partition')
    await expect(a.initialize()).rejects.toThrow('revoked')
    expect((await b.lookup('owner'))?.host_id).toBe('a')
    const recovered = await b.recover('owner', { fence: async h => ({ hostId: h.id, resource: h.resource, provider: 'azure', verifiedAt: new Date().toISOString(), state: 'PowerState/deallocated' }) })
    expect(recovered.generation).toBe('2')
    await expect(a.assertOwner('owner', row.generation)).rejects.toThrow()
    await expect(a.publish('owner', row.generation, {})).rejects.toThrow()
    await b.release('owner', recovered.generation)
    expect((await b.claim('owner')).generation).toBe('3')
  })
  it('refuses incompatible target and receipts bound to another resource', async () => {
    const row = await a.claim('owner'); await a.publish('owner', row.generation, {})
    await pool.query("UPDATE caboose_cluster_computers SET expires_at=clock_timestamp()-interval '1 second'")
    const c = new Coordinator(pool, { ...host('c'), compatibility: 'different' }); await c.initialize()
    await expect(c.recover('owner', { fence: vi.fn() })).rejects.toThrow('compatible')
    await expect(b.recover('owner', { fence: async h => ({ hostId: h.id, resource: 'wrong', provider:'azure',state:'PowerState/deallocated',verifiedAt:new Date().toISOString() }) })).rejects.toThrow('receipt')
  })
})

it('fails closed on coordinator failure, disconnecting sockets and stopping execution', async () => {
  const stop = vi.fn(async () => {}), disconnect = vi.fn()
  const coordinator = { ttlMs: 1000, assertOwner: async () => { throw new Error('partition') } } as unknown as Coordinator
  const guard = new ExecutionGuard(coordinator, { id:'owner',generation:'1',host_id:'a',checkpoint:null,compatibility:'x',expired:false }, stop, disconnect)
  await expect(guard.assert()).rejects.toThrow('partition')
  expect(stop).toHaveBeenCalledOnce(); expect(disconnect).toHaveBeenCalledOnce()
  await expect(guard.assert()).rejects.toThrow('fenced')
})
it('Azure 202 acceptance is not proof; independently checks instanceView', async () => {
  const calls: string[] = []
  const provider = new AzureFence((async (url: string | URL | Request) => {
    calls.push(String(url))
    if (calls.length === 1) return Response.json({ access_token: 'test-only' })
    if (calls.length === 2) return new Response(null, { status:202 })
    return Response.json({ statuses:[{ code:'PowerState/deallocated' }] })
  }) as typeof fetch)
  expect((await provider.fence(host('a'))).hostId).toBe('a')
  expect(calls[2]).toContain('/instanceView?')
})
it('refuses unverifiable provider state after accepted deallocation', async () => {
  let calls = 0
  const provider = new AzureFence((async () => ++calls === 1 ? Response.json({ access_token:'test-only' }) : new Response(null, { status:calls === 2 ? 202 : 503 })) as typeof fetch)
  await expect(provider.fence(host('a'))).rejects.toThrow('verification failed')
})
