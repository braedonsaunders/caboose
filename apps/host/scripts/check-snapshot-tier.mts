#!/usr/bin/env -S node --import tsx
import { createStorageFromEnv } from '@braedonsaunders/appkit-storage/env'
import { mkdtemp, mkdir, readFile, rm, writeFile } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { snapshotTierKey } from '../src/snapshot-tier-config.js'
import { SnapshotTier } from '../src/snapshot-tier.js'

const key = await snapshotTierKey(process.env, 'microvm')
if (!key) throw new Error('Set CABOOSE_SNAPSHOT_TIER=on and configure the snapshot key and storage')
const root = await mkdtemp(join(tmpdir(), 'caboose-snapshot-check-'))
const snapshot = join(root, 'check.snapshot')
const store = createStorageFromEnv(process.env)
const tier = new SnapshotTier(snapshot, store, key, async work => work(1), () => true)
let cleanupOk = false
try {
  await mkdir(snapshot)
  await writeFile(join(snapshot, 'memory-ranges'), 'disposable snapshot check\n')
  await tier.archive()
  await tier.restoreForWake()
  if (await readFile(join(snapshot, 'memory-ranges'), 'utf8') !== 'disposable snapshot check\n') throw new Error('Restored snapshot differs')
  await tier.discard()
  await tier.drainCleanup()
  cleanupOk = true
  console.log('Encrypted snapshot upload, verification, restore and cleanup passed')
} finally {
  if (cleanupOk) await rm(root, { recursive: true, force: true })
  else console.error(`Snapshot check did not finish cleanup; retain its receipts at ${root}`)
}
