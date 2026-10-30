import { copyFile, mkdir, mkdtemp, readFile, rm, rename, access, link, open } from 'node:fs/promises'
import { constants } from 'node:fs'
import { join } from 'node:path'
import { randomUUID } from 'node:crypto'
import type { ComputerRecord } from '../computers.js'
import type { ComputerSettings } from '../settings.js'
import { writePrivateJson } from '../settings.js'
import type { ComputerLifecycle } from '../lifecycle.js'
import type { PortableComputerStore, Compatibility, PortableCheckpointRef } from '../portable-storage/index.js'
import type { Coordinator, FenceProvider, Ownership } from './coordinator.js'
import { OwnershipError } from './coordinator.js'

export const stateFiles = ['caboose.json','agent-profiles.json','mcp-library.json','agent-tool-receipts.json','agent-routines.json','push-devices.json','activities.json']
export class Recovery {
  constructor(readonly coordinator: Coordinator, readonly archives: PortableComputerStore, readonly compatibility: Compatibility, readonly root: string, readonly provider: FenceProvider) {}
  directory(id: string, generation: string) { return join(this.root, 'cluster', id, generation) }
  async capture(row: Ownership, record: ComputerRecord, settings: ComputerSettings, lifecycle: ComputerLifecycle<unknown>, sourceRoot: string, dataDir: string) {
    const parent = join(this.root, 'cluster-captures')
    await mkdir(parent, { recursive: true, mode: 0o700 })
    return lifecycle.parkedExclusive(async generation => {
      await this.coordinator.assertOwner(row.id, row.generation)
      const stage = await mkdtemp(join(parent, 'capture-'))
      try {
        // Parked lifecycle exclusion holds until upload settles; the VMM is absent.
        // Atomic JSON writers yield a complete version of each independent host-state file.
        await copyFile(join(sourceRoot, 'overlays', `${row.id}.raw`), join(stage, 'disk.raw'), constants.COPYFILE_FICLONE)
        for (const name of ['vmlinux', 'initrd']) await copyFile(join(sourceRoot, name), join(stage, name))
        await copyFile(join(dataDir, 'keyring-secret'), join(stage, 'keyring-secret'))
        for (const name of stateFiles) await copyFile(join(dataDir, name), join(stage, name)).catch(error => { if (error.code !== 'ENOENT') throw error })
        await writePrivateJson(join(stage, 'computer.json'), { version: 1, record, settings })
        const ref = await this.archives.capture({ withCapture: work => work({ directory: stage, metadata: { ...this.compatibility, computerId: row.id, imageFormat: 'monolithic', createdAt: new Date().toISOString() } }) }, join(parent, `${randomUUID()}.json`))
        if (!lifecycle.isParkedGenerationCurrent(generation)) throw new OwnershipError('Capture cancelled by lifecycle transition')
        await this.coordinator.publish(row.id, row.generation, ref)
        return ref
      } finally { await rm(stage, { recursive: true, force: true }) }
    })
  }
  async recover(id: string): Promise<Ownership> {
    const old = await this.coordinator.lookup(id)
    if (!old?.checkpoint) throw new OwnershipError('No durable checkpoint exists')
    const manifest = await this.archives.inspect(old.checkpoint as PortableCheckpointRef, this.compatibility)
    if (manifest.metadata.computerId !== id || manifest.metadata.imageFormat !== 'monolithic') throw new OwnershipError('Unsupported checkpoint identity or image layout')
    const row = old.host_id ? await this.coordinator.recover(id, this.provider) : await this.coordinator.claim(id)
    let lost = false
    const renew = setInterval(() => { void this.coordinator.renew(id, row.generation).catch(() => { lost = true }) }, this.coordinator.ttlMs / 3)
    try {
      const directory = this.directory(id, row.generation)
      await mkdir(join(this.root, 'cluster', id), { recursive: true, mode: 0o700 })
      const stage = `${directory}.restoring`
      const restored = await this.archives.restore(row.checkpoint as PortableCheckpointRef, this.compatibility, stage)
      if (restored.metadata.computerId !== id || restored.metadata.imageFormat !== 'monolithic') throw new OwnershipError('Restored checkpoint identity mismatch')
      await this.coordinator.assertOwner(id, row.generation)
      if (lost) throw new OwnershipError('Ownership lost during restore')
      // The existing overlay is authoritative; AppKit still requires the matching base path.
      await link(join(this.root, 'base.raw'), join(stage, 'base.raw'))
      await mkdir(join(stage, 'overlays'), { mode: 0o700 })
      await rename(join(stage, 'disk.raw'), join(stage, 'overlays', `${id}.raw`))
      // Per-generation directory is the activation transaction. Partial directories never boot.
      await writePrivateJson(join(stage, 'activation.json'), { computerId: id, generation: row.generation, checkpoint: row.checkpoint })
      const activation = await open(join(stage, 'activation.json'), 'r')
      try { await activation.sync() } finally { await activation.close() }
      await rename(stage, directory)
      const parent = await open(join(this.root, 'cluster', id), 'r')
      try { await parent.sync() } finally { await parent.close() }
      return row
    } catch(error) {
      // No execution has started; release allows retry without a fake provider fence.
      await this.coordinator.release(id, row.generation).catch(() => {})
      throw error
    } finally { clearInterval(renew) }
  }
  async activated(row: Ownership): Promise<string | undefined> {
    const directory = this.directory(row.id, row.generation)
    try { await access(join(directory, 'activation.json')); return directory } catch { return undefined }
  }
}
