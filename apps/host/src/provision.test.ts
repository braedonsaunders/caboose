import { createHash } from 'node:crypto'
import { existsSync } from 'node:fs'
import { mkdtemp, readFile, rm, stat, writeFile } from 'node:fs/promises'
import { createServer, type Server } from 'node:http'
import type { AddressInfo } from 'node:net'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { zstdCompressSync } from 'node:zlib'
import { afterEach, beforeEach, expect, test, vi } from 'vitest'
import { containerImage, describeImage, microvmImage, parseReference, sparseWriter } from './provision.js'

const digest = (bytes: Buffer) => `sha256:${createHash('sha256').update(bytes).digest('hex')}`

let root: string
beforeEach(async () => { root = await mkdtemp(join(tmpdir(), 'caboose-provision-')) })
afterEach(async () => { await rm(root, { recursive: true, force: true }) })

test('parses registry references and prefers a digest over a tag', () => {
  expect(parseReference('ghcr.io/braedonsaunders/caboose-base:v0.2.0')).toEqual({ registry: 'ghcr.io', repository: 'braedonsaunders/caboose-base', reference: 'v0.2.0' })
  expect(parseReference('ghcr.io/owner/base')).toEqual({ registry: 'ghcr.io', repository: 'owner/base', reference: 'latest' })
  const pinned = `sha256:${'a'.repeat(64)}`
  expect(parseReference(`localhost:5000/base:v1@${pinned}`)).toEqual({ registry: 'localhost:5000', repository: 'base', reference: pinned })
  expect(() => parseReference('caboose-computer:latest')).toThrow(/must name its registry/)
  expect(() => parseReference('ghcr.io/owner/base@sha256:short')).toThrow(/digest/)
  expect(() => parseReference('ghcr.io/Owner/Base')).toThrow(/repository/)
})

test('writes whole zero blocks as holes and keeps the exact size', async () => {
  // 64 MiB of zeroes: APFS (unlike XFS and ext4) fills smaller gaps instead of leaving a hole.
  const data = Buffer.concat([Buffer.from('boot'), Buffer.alloc(64 * 1024 * 1024), Buffer.from('home'), Buffer.alloc(100)])
  const writer = await sparseWriter(join(root, 'disk'))
  await new Promise<void>((resolve, reject) => {
    writer.on('finish', resolve).on('error', reject)
    for (let offset = 0; offset < data.length; offset += 65_521) writer.write(data.subarray(offset, offset + 65_521))
    writer.end()
  })
  const written = await readFile(join(root, 'disk'))
  expect(written.equals(data)).toBe(true)
  expect((await stat(join(root, 'disk'))).blocks * 512).toBeLessThan(data.length / 2)
})

interface Fixture { files: Record<string, Buffer>; tamper?: string; pulls: string[] }

/** A registry that, like ghcr.io, demands an anonymous bearer token. */
async function registry(fixture: Fixture): Promise<{ server: Server; reference: (pin?: boolean) => string }> {
  const blobs = new Map(Object.values(fixture.files).map(bytes => [digest(bytes), bytes]))
  const layers = Object.entries(fixture.files).map(([title, bytes]) => ({
    mediaType: 'application/octet-stream', digest: digest(bytes), size: bytes.length, annotations: { 'org.opencontainers.image.title': title },
  }))
  const manifest = Buffer.from(JSON.stringify({ schemaVersion: 2, mediaType: 'application/vnd.oci.image.manifest.v1+json', layers }))
  const server = createServer((request, response) => {
    const url = new URL(request.url ?? '/', 'http://registry')
    if (url.pathname === '/token') {
      expect(url.searchParams.get('scope')).toBe('repository:caboose/base:pull')
      return response.end(JSON.stringify({ token: 'anonymous' }))
    }
    if (request.headers.authorization !== 'Bearer anonymous') {
      const { port } = server.address() as AddressInfo
      response.writeHead(401, { 'www-authenticate': `Bearer realm="http://127.0.0.1:${port}/token",service="test",scope="repository:caboose/base:pull"` })
      return response.end()
    }
    if (url.pathname === '/v2/caboose/base/manifests/v1' || url.pathname === `/v2/caboose/base/manifests/${digest(manifest)}`) {
      return response.end(manifest)
    }
    const blob = /^\/v2\/caboose\/base\/blobs\/(sha256:[0-9a-f]+)$/.exec(url.pathname)?.[1]
    const bytes = blob ? blobs.get(blob) : undefined
    if (!blob || !bytes) { response.writeHead(404); return response.end() }
    fixture.pulls.push(blob)
    const title = layers.find(layer => layer.digest === blob)?.annotations['org.opencontainers.image.title']
    response.end(title === fixture.tamper ? Buffer.concat([bytes.subarray(0, -1), Buffer.from('x')]) : bytes)
  })
  await new Promise<void>(resolve => server.listen(0, '127.0.0.1', resolve))
  const { port } = server.address() as AddressInfo
  return { server, reference: pin => pin ? `127.0.0.1:${port}/caboose/base@${digest(manifest)}` : `127.0.0.1:${port}/caboose/base:v1` }
}

const disk = Buffer.concat([Buffer.from('partition table'), Buffer.alloc(8 * 1024 * 1024), Buffer.from('root filesystem')])
const files = () => ({ 'base.raw.zst': zstdCompressSync(disk), vmlinux: Buffer.from('kernel'), initrd: Buffer.from('initramfs') })

test('fetches a missing microVM image, verifies it and decompresses the disk', async () => {
  const fixture: Fixture = { files: files(), pulls: [] }
  const { server, reference } = await registry(fixture)
  try {
    const image = microvmImage({ imageRoot: root, reference: reference(true) })
    await image.ensure()
    expect(image.status()).toEqual({ state: 'ready', reference: reference(true) })
    expect((await readFile(join(root, 'base.raw'))).equals(disk)).toBe(true)
    expect(await readFile(join(root, 'vmlinux'), 'utf8')).toBe('kernel')
    expect(await readFile(join(root, 'initrd'), 'utf8')).toBe('initramfs')
    expect(existsSync(join(root, 'base.raw.part'))).toBe(false)
    // Present files are never fetched again.
    await microvmImage({ imageRoot: root, reference: reference(true) }).ensure()
    expect(fixture.pulls).toHaveLength(3)
  } finally {
    server.close()
  }
})

test('rejects a blob that does not match its digest and leaves nothing behind', async () => {
  const fixture: Fixture = { files: files(), tamper: 'vmlinux', pulls: [] }
  const { server, reference } = await registry(fixture)
  try {
    const image = microvmImage({ imageRoot: root, reference: reference() })
    await expect(image.ensure()).rejects.toThrow(/does not match its digest/)
    expect(image.status()).toMatchObject({ state: 'failed', message: 'The downloaded vmlinux does not match its digest' })
    expect(existsSync(join(root, 'vmlinux'))).toBe(false)
    expect(existsSync(join(root, 'vmlinux.part'))).toBe(false)
    // The disk that did verify is kept, so a retry fetches only what is missing.
    expect(existsSync(join(root, 'base.raw'))).toBe(true)
  } finally {
    server.close()
  }
})

test('rejects a manifest that does not match its pinned digest', async () => {
  const fixture: Fixture = { files: files(), pulls: [] }
  const { server, reference } = await registry(fixture)
  try {
    const wrong = reference(true).replace(/@sha256:.*/, `@sha256:${'0'.repeat(64)}`)
    await expect(microvmImage({ imageRoot: root, reference: wrong }).ensure()).rejects.toThrow()
    expect(fixture.pulls).toHaveLength(0)
  } finally {
    server.close()
  }
})

test('an image the host was given no reference for is missing, not failed', async () => {
  const image = microvmImage({ imageRoot: root, reference: null })
  await image.ensure()
  expect(image.status()).toEqual({ state: 'missing', reference: null })
  await Promise.all(['base.raw', 'vmlinux', 'initrd'].map(file => writeFile(join(root, file), file)))
  await image.ensure()
  expect(image.status().state).toBe('ready')
})

test('pulls a registry container image only when Docker lacks it', async () => {
  const docker = vi.fn(async (args: string[]) => { if (args[0] === 'image') throw new Error('No such image') })
  const image = containerImage({ image: 'ghcr.io/owner/caboose-computer@sha256:' + 'b'.repeat(64), docker })
  await image.ensure()
  expect(docker.mock.calls.map(call => call[0][0])).toEqual(['image', 'pull'])
  expect(image.status().state).toBe('ready')

  const local = containerImage({ image: 'caboose-computer:latest', docker })
  await local.ensure()
  expect(local.status()).toEqual({ state: 'missing', reference: null })

  const failing = containerImage({ image: 'ghcr.io/owner/computer:v1', docker: async () => { throw new Error('denied') } })
  await expect(failing.ensure()).rejects.toThrow("Downloading the computer's image failed: denied")
})

test('describes progress for an owner', () => {
  expect(describeImage({ state: 'fetching', reference: 'r', receivedBytes: 42, totalBytes: 100 })).toBe("Downloading the computer's image (42%)")
  expect(describeImage({ state: 'failed', reference: 'r', message: 'offline' })).toBe("Downloading the computer's image failed: offline")
})
