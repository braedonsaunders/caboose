import { afterAll, describe, expect, it } from 'vitest'
import pg from 'pg'
import { randomBytes } from 'node:crypto'
import { mkdtemp, mkdir, writeFile, readFile, rm } from 'node:fs/promises'
import { join } from 'node:path'
import { tmpdir } from 'node:os'
import { createStorage } from '@braedonsaunders/appkit-storage'
import { createRequire } from 'node:module'
const localRequire = createRequire(import.meta.url)
const { CreateBucketCommand } = createRequire(localRequire.resolve('@braedonsaunders/appkit-storage'))('@aws-sdk/client-s3')
import { Coordinator } from './coordinator.js'
import { Recovery } from './recovery.js'
import { PortableComputerStore } from '../portable-storage/index.js'
import { ComputerLifecycle } from '../lifecycle.js'
import { PhoneTokens } from '../computers.js'

const url = process.env.CABOOSE_TEST_CLUSTER_DATABASE_URL
const endpoint = process.env.CABOOSE_TEST_MINIO_ENDPOINT
// Explicit disposable services only. No production env variables are consumed.
describe.skipIf(!url || !endpoint)('real PostgreSQL + S3 cold activation with synthetic controller/fence', () => {
  const pool = new pg.Pool({ connectionString: url, max: 4, query_timeout: 3000 })
  const objects = createStorage({ endpoint: endpoint!, bucket: 'cluster-acceptance', accessKeyId:'disposable', secretAccessKey:'disposable-test-only', region:'us-east-1' })
  afterAll(async () => { await pool.end(); objects.client.destroy() })
  it('captures under lifecycle exclusion, loses source, restores to fenced generation with phone identity intact', async () => {
    await objects.client.send(new CreateBucketCommand({ Bucket:'cluster-acceptance' }))
    const root = await mkdtemp(join(tmpdir(), 'cluster-acceptance-'))
    const source = join(root,'source'), target = join(root,'target')
    await mkdir(join(source,'overlays'), { recursive:true }); await mkdir(target)
    const disk = randomBytes(1024*1024), keyring = randomBytes(32).toString('hex')
    const compatibility = { runtime:'linux-microvm' as const, architecture:'x64' as const, runtimeVersion:'synthetic-acceptance' }
    const host = (id: string) => ({ id,resource:`resource-${id}`,compatibility:JSON.stringify(compatibility),endpoint:`https://${id}.example.invalid` })
    const a = new Coordinator(pool,host('source')), b = new Coordinator(pool,host('target'))
    await a.initialize(); await pool.query('TRUNCATE caboose_cluster_computers,caboose_cluster_hosts'); await a.initialize(); await b.initialize(); await a.enroll('owner')
    const row = await a.claim('owner')
    const archives = new PortableComputerStore(objects, randomBytes(32))
    const receipt = { fence: async (h: ReturnType<typeof host>) => ({ resource:h.resource,hostId:h.id,provider:'azure' as const,state:'PowerState/deallocated' as const,verifiedAt:new Date().toISOString() }) }
    const capture = new Recovery(a,archives,compatibility,source,receipt), restore = new Recovery(b,archives,compatibility,target,receipt)
    try {
      for (const directory of [source,target]) for (const name of ['base.raw','vmlinux','initrd']) await writeFile(join(directory,name), name)
      await writeFile(join(source,'overlays','owner.raw'),disk)
      await writeFile(join(source,'keyring-secret'),keyring)
      const settings = { name:'Recovered',defaultAgent:null,memoryMb:512,vcpus:1,idleMs:3000 }
      await writeFile(join(source,'caboose.json'),JSON.stringify(settings))
      const lifecycle = new ComputerLifecycle({wake:async()=>({}),park:async()=>{}},3000)
      const phoneA = await PhoneTokens.open(join(source,'phones.json'),pool)
      const minted = await phoneA.mint('owner','Fixture phone')
      const ref = await capture.capture(row,{id:'owner',slot:0,createdAt:null,tenantId:null,person:null},settings,lifecycle,source,source)
      expect(ref.version).toBe(1)
      await rm(source,{recursive:true})
      await pool.query("UPDATE caboose_cluster_computers SET expires_at=clock_timestamp()-interval '1 second' WHERE id='owner'")
      const recovered = await restore.recover('owner')
      expect(recovered.generation).toBe('2')
      const activated = await restore.activated(recovered)
      expect(await readFile(join(activated!,'overlays','owner.raw'))).toEqual(disk)
      expect(await readFile(join(activated!,'keyring-secret'),'utf8')).toBe(keyring)
      expect(JSON.parse(await readFile(join(activated!,'computer.json'),'utf8')).settings.name).toBe('Recovered')
      const phoneB = await PhoneTokens.open(join(target,'phones.json'),pool)
      expect(phoneB.resolve(minted.token)?.computerId).toBe('owner')
      await phoneA.revoke('owner',minted.phone.id); await phoneB.refresh()
      expect(phoneB.resolve(minted.token)).toBeUndefined()
      await expect(a.assertOwner('owner','1')).rejects.toThrow()
      // Corrupt a real S3 object: no next generation directory may activate.
      const manifest = await archives.inspect(ref,compatibility)
      await objects.putStream({key:manifest.archive.entries.find(e=>e.name==='disk.raw')!.key,body:(async function*(){yield Buffer.from('damaged')})()})
      await b.release('owner','2')
      await expect(restore.recover('owner')).rejects.toThrow()
      expect(await restore.activated({...recovered,generation:'3'})).toBeUndefined()
      expect((await b.lookup('owner'))?.host_id).toBeNull()
    } finally { await rm(root,{recursive:true,force:true}) }
  })
})
