import { createHash } from 'node:crypto'

/** Guest Files derives versions from its original device, not the reader mount. */
export function parkedFileIdentity(device: bigint, inode: bigint, size: bigint, mtimeNs: bigint, ctimeNs: bigint): { identity: string; etag: string } {
  if ([device, inode, size].some(value => value < 0n)) throw new Error('Invalid parked file metadata')
  const identity = `${device}:${inode}`
  const payload = `${identity}:${size}:${mtimeNs}:${ctimeNs}`
  return { identity, etag: `"${createHash('sha256').update(payload).digest('hex')}"` }
}
