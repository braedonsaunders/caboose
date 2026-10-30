import type { Controller } from '../server.js'
import type { Coordinator, Ownership } from './coordinator.js'
import { OwnershipError } from './coordinator.js'
import type { Recovery } from './recovery.js'
import { ExecutionGuard } from './guard.js'

export class ClusterRuntime {
  readonly owned = new Map<string, Ownership>()
  readonly guards = new Map<string, ExecutionGuard>()
  readonly roots = new Map<string, string>()
  disconnect: (id: string) => void = () => {}
  constructor(readonly coordinator: Coordinator, readonly recovery: Recovery, readonly root: string) {}
  async authorize(id: string) {
    const guard = this.guards.get(id)
    if (!guard) {
      const row = await this.coordinator.lookup(id)
      const host = row?.host_id && (await this.coordinator.pool.query('SELECT endpoint FROM caboose_cluster_hosts WHERE id=$1 AND NOT revoked', [row.host_id])).rows[0]
      throw new OwnershipError(host ? `Computer is owned by ${host.endpoint}` : 'Computer needs cluster claim or recovery')
    }
    await guard.assert()
  }
  wrap(id: string, controller: Controller) {
    const row = this.owned.get(id)
    if (!row) return new Proxy(controller, { get(target, key) {
      if (['wake','restart','promote','thaw','launch','ensureAgentSeat','apps','parkedFilesView'].includes(String(key))) return async () => { throw new OwnershipError('Computer is not owned on this host') }
      if (key === 'guest') return () => undefined
      const value = Reflect.get(target, key, target)
      return typeof value === 'function' ? value.bind(target) : value
    } })
    if (!controller.stopExecution) throw new Error('Runtime has no execution stop primitive')
    this.guards.get(id)?.close()
    const guard = new ExecutionGuard(this.coordinator, row, () => controller.stopExecution!(), () => this.disconnect(id))
    this.guards.set(id, guard); guard.start()
    return guard.wrap(controller)
  }
  async claim(id: string) {
    await this.coordinator.enroll(id)
    const existing = await this.coordinator.lookup(id)
    if (existing?.checkpoint) throw new OwnershipError('Use recovery for a checkpointed computer')
    const row = await this.coordinator.claim(id)
    this.owned.set(id, row)
    this.roots.set(id, this.root)
  }
  async recover(id: string) {
    const row = await this.recovery.recover(id)
    this.owned.set(id, row)
    this.roots.set(id, this.recovery.directory(id, row.generation))
  }
  async close() { await Promise.all([...this.guards.values()].map(g => g.fence())) }
}
