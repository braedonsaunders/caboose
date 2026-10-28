import type { Pool, PoolClient } from 'pg'
import type { ComputerRecord } from '../computers.js'
import { SettingsInputError } from '../settings.js'

/** SQL is authoritative after import. The old JSON file is left intact for recovery. */
export class ComputerStore {
  constructor(private pool: Pool) {}

  async initialize(legacy: ComputerRecord[]): Promise<ComputerRecord[]> {
    await this.transaction(async client => {
      // One host owns a state directory. The lock also makes first-open imports atomic.
      await client.query('LOCK TABLE caboose_computers IN EXCLUSIVE MODE')
      if ((await client.query('SELECT id FROM caboose_computers LIMIT 1')).rowCount) return
      for (const record of legacy) {
        let personId: string | null = null
        if (record.tenantId && record.person) {
          // A name is not an identity: never collapse different legacy people by name.
          const person = await client.query('INSERT INTO caboose_people(tenant_id,name) VALUES($1,$2) RETURNING id', [record.tenantId, record.person])
          personId = person.rows[0].id
        }
        await this.upsert(client, { ...record, personId })
      }
    })
    return this.load()
  }

  async load(): Promise<ComputerRecord[]> {
    return this.read(this.pool)
  }

  private async read(client: Pick<Pool, 'query'> | Pick<PoolClient, 'query'>): Promise<ComputerRecord[]> {
    const { rows } = await client.query(`SELECT c.id,c.slot,c.created_at,c.tenant_id,c.person_id,COALESCE(p.name,c.legacy_person) AS person
      FROM caboose_computers c LEFT JOIN caboose_people p ON p.id=c.person_id ORDER BY c.slot`)
    return rows.map(row => ({ id: row.id, slot: row.slot, createdAt: row.created_at?.toISOString() ?? null,
      tenantId: row.tenant_id, personId: row.person_id, person: row.person }))
  }

  async save(previous: ComputerRecord[], next: ComputerRecord[]): Promise<ComputerRecord[]> {
    return this.transaction(async client => {
      for (const record of previous) if (!next.some(candidate => candidate.id === record.id)) {
        await client.query('DELETE FROM caboose_computers WHERE id=$1', [record.id])
      }
      for (const record of next) {
        const old = previous.find(candidate => candidate.id === record.id)
        if (JSON.stringify(old) === JSON.stringify(record)) continue
        let personId = record.personId ?? null
        if (!personId && record.tenantId && record.person) {
          const person = await client.query('INSERT INTO caboose_people(tenant_id,name) VALUES($1,$2) RETURNING id', [record.tenantId, record.person])
          personId = person.rows[0].id
        }
        await this.upsert(client, { ...record, personId })
      }
      return this.read(client)
    })
  }

  private async upsert(client: PoolClient, record: ComputerRecord) {
    await client.query(`INSERT INTO caboose_computers(id,slot,created_at,tenant_id,person_id,assignment_pending,legacy_person)
      VALUES($1,$2,$3,$4,$5,$6,$7) ON CONFLICT(id) DO UPDATE SET
      tenant_id=EXCLUDED.tenant_id,person_id=EXCLUDED.person_id,assignment_pending=EXCLUDED.assignment_pending,legacy_person=EXCLUDED.legacy_person`,
    [record.id, record.slot, record.createdAt, record.tenantId, record.personId ?? null, !record.personId, record.personId ? null : record.person])
  }

  private async transaction<T>(work: (client: PoolClient) => Promise<T>): Promise<T> {
    const client = await this.pool.connect()
    try {
      await client.query('BEGIN')
      const result = await work(client)
      await client.query('COMMIT')
      return result
    } catch (error) {
      await client.query('ROLLBACK')
      if (error && typeof error === 'object' && 'code' in error && error.code === '23503') {
        throw new SettingsInputError('The person or tenant changed; select a person in the destination tenant and retry')
      }
      throw error
    } finally { client.release() }
  }
}
