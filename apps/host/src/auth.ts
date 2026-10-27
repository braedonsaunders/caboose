import { createHash, timingSafeEqual } from 'node:crypto'

/** Hash both values to fixed length before the constant-time comparison. */
export function authenticate(header: string | undefined, ownerToken: string): boolean {
  if (!ownerToken || !header?.startsWith('Bearer ')) return false
  const candidate = header.slice(7)
  if (!candidate) return false
  const digest = (value: string) => createHash('sha256').update(value, 'utf8').digest()
  return timingSafeEqual(digest(candidate), digest(ownerToken))
}
