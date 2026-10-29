import { parseExecResult, type DeskMachine } from '@braedonsaunders/appkit-desk'
import { ParkedFilesJournal, type FreezeBranch, type ParkedFreezeIntent } from './parked-files-journal.js'

export interface ParkedFilesHooks {
  beforePark(machine: DeskMachine): Promise<void>
  onPaused(): Promise<void>
  onParked(snapshotDirectory: string): Promise<void>
  onPausedError(error: unknown): void
}

interface PreparedGuest { branches: FreezeBranch[]; homeDevice: number }
interface StagedDisk { directory: string; image: string }

/** Runs one optional sidecar attempt. No stage is published without the backend's
 * positive durable-snapshot callback and a completed suspend. The caller fences
 * wake/delete and invalidates its published view before guest access. */
export class ParkedFilesController {
  constructor(private readonly journal: ParkedFilesJournal, private readonly stage: () => Promise<StagedDisk>, private readonly discard: (stage: StagedDisk) => Promise<void>, private readonly publish: (stage: StagedDisk, intent: Extract<ParkedFreezeIntent, { version: 2 }>, snapshotDirectory: string) => Promise<void>) {}

  async park(suspend: (hooks: ParkedFilesHooks) => Promise<void>): Promise<boolean> {
    let intent: Extract<ParkedFreezeIntent, { version: 2 }> | undefined
    let staged: StagedDisk | undefined
    let snapshotDirectory: string | undefined
    let failed = false
    const run = async (machine: DeskMachine, args: string[]) => {
      const result = parseExecResult(await machine.request({ op: 'exec', command: '/usr/bin/python3', args: ['/opt/caboose/files/parked_quiesce.py', ...args], timeoutMs: 60_000 }))
      if (result.exitCode !== 0 || result.truncated) throw new Error('Guest parked Files preparation failed')
      return result.stdout
    }
    const hooks: ParkedFilesHooks = {
      beforePark: async machine => {
        const raw = await run(machine, ['prepare'])
        let prepared: PreparedGuest
        try { prepared = JSON.parse(raw) as PreparedGuest } catch { throw new Error('Invalid parked Files preparation') }
        if (!prepared || typeof prepared !== 'object' || Array.isArray(prepared) || Object.keys(prepared).sort().join(',') !== 'branches,homeDevice' || !Array.isArray(prepared.branches) || !Number.isSafeInteger(prepared.homeDevice) || prepared.homeDevice < 0) throw new Error('Invalid parked Files preparation')
        const recorded = await this.journal.begin(prepared.branches, prepared.homeDevice)
        if (recorded.version !== 2 || recorded.homeDevice === undefined) throw new Error('Invalid parked Files intent')
        intent = recorded
        await run(machine, ['freeze', JSON.stringify({ branches: recorded.branches, homeDevice: recorded.homeDevice })])
      },
      onPaused: async () => {
        if (!intent || failed) throw new Error('Parked Files was not prepared')
        staged = await this.stage()
      },
      onParked: async directory => {
        if (!intent || !staged || failed || !directory) throw new Error('Parked Files stage unavailable')
        snapshotDirectory = directory
      },
      onPausedError: () => { failed = true },
    }
    try {
      await suspend(hooks)
      if (failed || !intent || !staged || !snapshotDirectory) return false
      await this.publish(staged, intent, snapshotDirectory)
      staged = undefined
      return true
    } finally {
      if (staged) await this.discard(staged)
    }
  }
}
