import { mkdtemp, rm, stat, writeFile } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { afterEach, beforeEach, expect, test } from 'vitest'
import { ownerToken } from './owner-token.js'

let root: string
beforeEach(async () => { root = await mkdtemp(join(tmpdir(), 'caboose-owner-')) })
afterEach(async () => { await rm(root, { recursive: true, force: true }) })

test('generates a private owner token once and reuses it', async () => {
  const path = join(root, 'state', 'owner-token')
  const first = await ownerToken(path)
  expect(first.created).toBe(true)
  expect(first.token).toMatch(/^[0-9a-f]{64}$/)
  expect((await stat(path)).mode & 0o777).toBe(0o600)
  expect(await ownerToken(path)).toEqual({ token: first.token, created: false })
})

test('refuses a token file too short to be a secret', async () => {
  const path = join(root, 'owner-token')
  await writeFile(path, 'short\n')
  await expect(ownerToken(path)).rejects.toThrow(/no usable owner token/)
})
