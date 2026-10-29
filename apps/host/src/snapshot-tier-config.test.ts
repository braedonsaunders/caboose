import { mkdtemp, rm, writeFile, chmod, symlink } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { expect, it } from 'vitest'
import { snapshotTierKey } from './snapshot-tier-config.js'

it('requires an explicit private key when snapshot tiering is enabled', async () => {
  const root = await mkdtemp(join(tmpdir(), 'tier-key-')), key = join(root, 'key'), link = join(root, 'link')
  try {
    expect(await snapshotTierKey({}, 'microvm')).toBeUndefined()
    await writeFile(key, 'ab'.repeat(32), { mode: 0o600 })
    expect(await snapshotTierKey({ CABOOSE_SNAPSHOT_TIER: 'on', CABOOSE_SNAPSHOT_KEY_FILE: key }, 'microvm', 'linux')).toEqual(Buffer.from('ab'.repeat(32), 'hex'))
    await expect(snapshotTierKey({ CABOOSE_SNAPSHOT_TIER: 'on', CABOOSE_SNAPSHOT_KEY_FILE: key }, 'container', 'linux')).rejects.toThrow('microVM')
    await symlink(key, link)
    await expect(snapshotTierKey({ CABOOSE_SNAPSHOT_TIER: 'on', CABOOSE_SNAPSHOT_KEY_FILE: link }, 'microvm', 'linux')).rejects.toThrow()
    await chmod(key, 0o644)
    await expect(snapshotTierKey({ CABOOSE_SNAPSHOT_TIER: 'on', CABOOSE_SNAPSHOT_KEY_FILE: key }, 'microvm', 'linux')).rejects.toThrow('private')
  } finally { await rm(root, { recursive: true, force: true }) }
})
