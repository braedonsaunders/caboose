import type pg from 'pg'
import { clusterSchema } from './schema.js'

export interface Host { id: string; resource: string; compatibility: string; endpoint: string }
export interface Ownership { id: string; generation: string; host_id: string | null; checkpoint: unknown; compatibility: string; expired: boolean }
export interface FenceReceipt { resource: string; hostId: string; provider: 'azure'; verifiedAt: string; state: 'PowerState/deallocated' }
export interface FenceProvider { fence(host: Host): Promise<FenceReceipt> }
export class OwnershipError extends Error {}

/** PostgreSQL is the authority. No local-file or embedded fallback is accepted by startup. */
export class Coordinator {
  constructor(readonly pool: pg.Pool, readonly host: Host, readonly ttlMs = 30_000) {
    if (!Number.isSafeInteger(ttlMs) || ttlMs < 1000 || ttlMs > 300_000) throw new Error('Invalid cluster lease duration')
  }
  async initialize() {
    await this.pool.query(clusterSchema)
    await this.pool.query('INSERT INTO caboose_cluster_hosts(id,resource,compatibility,endpoint) VALUES($1,$2,$3,$4) ON CONFLICT(id) DO NOTHING', [this.host.id, this.host.resource, this.host.compatibility, this.host.endpoint])
    await this.assertHost()
  }
  async assertHost() {
    const { rows } = await this.pool.query('SELECT * FROM caboose_cluster_hosts WHERE id=$1 AND NOT revoked', [this.host.id])
    const h = rows[0]
    if (!h || h.resource !== this.host.resource || h.compatibility !== this.host.compatibility || h.endpoint !== this.host.endpoint) throw new OwnershipError('Host identity is revoked or configuration changed')
  }
  async lookup(id: string): Promise<Ownership | undefined> {
    return (await this.pool.query('SELECT *, expires_at <= clock_timestamp() AS expired FROM caboose_cluster_computers WHERE id=$1', [id])).rows[0]
  }
  /** Enrollment is explicit; an absent checkpoint never authorizes restoring a lost disk. */
  async enroll(id: string) {
    await this.assertHost()
    await this.pool.query('INSERT INTO caboose_cluster_computers(id,compatibility) VALUES($1,$2) ON CONFLICT DO NOTHING', [id, this.host.compatibility])
  }
  async claim(id: string): Promise<Ownership> {
    const c = await this.pool.connect()
    try {
      await c.query('BEGIN')
      // All ownership mutations lock the host first. Revocation cannot race a renewal.
      const host = (await c.query('SELECT * FROM caboose_cluster_hosts WHERE id=$1 FOR UPDATE', [this.host.id])).rows[0]
      if (!host || host.revoked) throw new OwnershipError('Host revoked')
      const row = (await c.query('SELECT *, expires_at <= clock_timestamp() AS expired FROM caboose_cluster_computers WHERE id=$1 FOR UPDATE', [id])).rows[0] as Ownership | undefined
      if (!row || row.compatibility !== this.host.compatibility) throw new OwnershipError('Computer absent or incompatible')
      // Expired self-leases cannot be revived: process restart must use verified recovery.
      if (row.host_id) throw new OwnershipError('Computer already has an execution owner; verified recovery required')
      const result = await c.query('UPDATE caboose_cluster_computers SET host_id=$2,generation=generation+1,expires_at=clock_timestamp()+$3*interval \'1 millisecond\' WHERE id=$1 RETURNING *, false AS expired', [id, this.host.id, this.ttlMs])
      await c.query('COMMIT')
      return result.rows[0]
    } catch (error) { await c.query('ROLLBACK'); throw error } finally { c.release() }
  }
  async renew(id: string, generation: string) {
    // Single statement locks host through a CTE before changing the lease.
    const result = await this.pool.query(`WITH h AS (SELECT id FROM caboose_cluster_hosts WHERE id=$2 AND NOT revoked FOR UPDATE)
      UPDATE caboose_cluster_computers SET expires_at=clock_timestamp()+$4*interval '1 millisecond'
      WHERE id=$1 AND host_id IN (SELECT id FROM h) AND generation=$3 AND expires_at>clock_timestamp() RETURNING id`, [id, this.host.id, generation, this.ttlMs])
    if (result.rowCount !== 1) throw new OwnershipError('Execution ownership lost')
  }
  async assertOwner(id: string, generation: string) {
    const r = await this.pool.query(`SELECT c.id FROM caboose_cluster_computers c JOIN caboose_cluster_hosts h ON h.id=c.host_id
      WHERE c.id=$1 AND c.host_id=$2 AND c.generation=$3 AND c.expires_at>clock_timestamp() AND NOT h.revoked`, [id, this.host.id, generation])
    if (r.rowCount !== 1) throw new OwnershipError('Execution ownership unavailable')
  }
  async publish(id: string, generation: string, checkpoint: unknown) {
    const r = await this.pool.query(`UPDATE caboose_cluster_computers SET checkpoint=$4 WHERE id=$1 AND host_id=$2 AND generation=$3 AND expires_at>clock_timestamp()
      AND EXISTS(SELECT 1 FROM caboose_cluster_hosts WHERE id=$2 AND NOT revoked) RETURNING id`, [id, this.host.id, generation, JSON.stringify(checkpoint)])
    if (r.rowCount !== 1) throw new OwnershipError('Checkpoint ownership lost')
  }
  /** Only after local execution has stopped. Expired leases require provider fencing. */
  async release(id: string, generation: string) {
    const r = await this.pool.query(`UPDATE caboose_cluster_computers SET host_id=NULL,expires_at=NULL WHERE id=$1 AND host_id=$2 AND generation=$3 AND expires_at>clock_timestamp()
      AND EXISTS(SELECT 1 FROM caboose_cluster_hosts WHERE id=$2 AND NOT revoked) RETURNING id`, [id, this.host.id, generation])
    if (r.rowCount !== 1) throw new OwnershipError('Cannot release stale ownership')
  }
  async recover(id: string, provider: FenceProvider): Promise<Ownership> {
    const row = await this.lookup(id)
    if (!row?.host_id || !row.expired || !row.checkpoint || row.compatibility !== this.host.compatibility) throw new OwnershipError('Recovery requires expired ownership and a compatible durable checkpoint')
    if (row.host_id === this.host.id) throw new OwnershipError('A host cannot fence itself for takeover')
    // Permanently revoke before contacting the provider. Any failed/ambiguous fence stays revoked.
    const c = await this.pool.connect()
    let old: Host
    try {
      await c.query('BEGIN')
      const h = (await c.query('SELECT * FROM caboose_cluster_hosts WHERE id=$1 FOR UPDATE', [row.host_id])).rows[0]
      const current = (await c.query('SELECT *,expires_at<=clock_timestamp() AS expired FROM caboose_cluster_computers WHERE id=$1 FOR UPDATE', [id])).rows[0]
      if (!h || current?.host_id !== row.host_id || current.generation !== row.generation || !current.expired) throw new OwnershipError('Ownership changed before fence')
      await c.query('UPDATE caboose_cluster_hosts SET revoked=true WHERE id=$1', [row.host_id])
      await c.query('COMMIT')
      old = { id: h.id, resource: h.resource, compatibility: h.compatibility, endpoint: h.endpoint }
    } catch (error) { await c.query('ROLLBACK'); throw error } finally { c.release() }
    const receipt = await provider.fence(old)
    if (receipt.resource !== old.resource || receipt.hostId !== old.id || receipt.provider !== 'azure' || receipt.state !== 'PowerState/deallocated') throw new OwnershipError('Invalid fencing receipt')
    // The receipt is tied to both the permanently revoked host and observed computer generation.
    const client = await this.pool.connect()
    try {
      await client.query('BEGIN')
      await client.query('UPDATE caboose_cluster_hosts SET fence_receipt=$2 WHERE id=$1 AND revoked', [old.id, JSON.stringify({ ...receipt, computerId: id, generation: row.generation })])
      const r = await client.query('UPDATE caboose_cluster_computers SET host_id=NULL,expires_at=NULL WHERE id=$1 AND host_id=$2 AND generation=$3 RETURNING id', [id, old.id, row.generation])
      if (r.rowCount !== 1) throw new OwnershipError('Recovery raced another owner')
      await client.query('COMMIT')
    } catch (error) { await client.query('ROLLBACK'); throw error } finally { client.release() }
    return this.claim(id)
  }
}
