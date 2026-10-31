import { createStorage } from '@braedonsaunders/appkit-storage'
import { snapshotTierKey } from '../snapshot-tier-config.js'
import { PortableComputerStore } from './index.js'

/** Separate credentials/key from memory tiering; disabled unless explicitly enabled. */
export async function openPortableStorage(env: NodeJS.ProcessEnv, runtime: 'microvm' | 'container', platform: NodeJS.Platform = process.platform) {
  if (env.CABOOSE_PORTABLE_STORAGE === undefined || env.CABOOSE_PORTABLE_STORAGE === 'off') return undefined
  if (env.CABOOSE_PORTABLE_STORAGE !== 'on') throw new Error('CABOOSE_PORTABLE_STORAGE must be on or off')
  const key = await snapshotTierKey({ CABOOSE_SNAPSHOT_TIER: 'on', CABOOSE_SNAPSHOT_KEY_FILE: env.CABOOSE_PORTABLE_KEY_FILE }, runtime, platform)
  for (const name of ['CABOOSE_PORTABLE_ENDPOINT', 'CABOOSE_PORTABLE_BUCKET', 'CABOOSE_PORTABLE_ACCESS_KEY_ID', 'CABOOSE_PORTABLE_SECRET_ACCESS_KEY']) if (!env[name]) throw new Error(`${name} is required`)
  const endpoint = new URL(env.CABOOSE_PORTABLE_ENDPOINT!)
  if (!['https:', 'http:'].includes(endpoint.protocol) || endpoint.username || endpoint.password) throw new Error('Invalid portable object endpoint')
  const objects = createStorage({ endpoint: endpoint.href, bucket: env.CABOOSE_PORTABLE_BUCKET!, accessKeyId: env.CABOOSE_PORTABLE_ACCESS_KEY_ID!, secretAccessKey: env.CABOOSE_PORTABLE_SECRET_ACCESS_KEY!, region: env.CABOOSE_PORTABLE_REGION ?? 'us-east-1' })
  return { archives: new PortableComputerStore(objects, key!), close: () => objects.client.destroy() }
}
