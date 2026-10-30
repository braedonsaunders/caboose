import { recoveryRoute } from './recovery.js'
import { createHash, randomBytes } from 'node:crypto'
import { chmod, copyFile, mkdir, mkdtemp, readFile, readdir, rm, writeFile } from 'node:fs/promises'
import { createServer, type Server } from 'node:http'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { fileURLToPath } from 'node:url'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { AgentNotFoundError } from './agents.js'
import { ComputerBackups, type BackupHost, type RestoreContext } from './backup.js'
import { ComputerConflictError, ComputerLifecycle } from './lifecycle.js'
import { SettingsInputError } from './settings.js'
import type { Principal } from './server.js'
import type { SystemImageBinding } from './system-image.js'

const MiB = 1024 * 1024
const phone: Principal = { kind: 'phone', phoneId: 'phone-1', computerId: 'c1' }

function chunk(fill: number | 'random'): Buffer {
  return fill === 'random' ? randomBytes(MiB) : Buffer.alloc(MiB, fill)
}

describe('computer backups', () => {
  let root: string
  let server: Server
  let url: string
  let backups: ComputerBackups
  let lifecycle: ComputerLifecycle<string>
  let disk: Buffer
  let base: Buffer
  let binding: SystemImageBinding | null
  const restarts: Array<{ image: string; binding: SystemImageBinding | null; content: Buffer }> = []
  let pending: { image: string; binding: SystemImageBinding | null } | undefined
  const context: RestoreContext = {
    restart: async stage => {
      await stage()
      const replacement = pending!
      pending = undefined
      restarts.push({ ...replacement, content: await readFile(replacement.image) })
    },
    checkDisk: async () => {},
    replaceDisk: replacement => { pending = replacement },
  }

  async function request(method: string, path: string, body?: unknown, raw?: Buffer): Promise<{ status: number; body: any; bytes: Buffer }> {
    const response = await fetch(url + path, { method, ...(raw ? { body: new Uint8Array(raw) } : body === undefined ? {} : { body: JSON.stringify(body) }) })
    const bytes = Buffer.from(await response.arrayBuffer())
    let parsed: unknown = undefined
    try { parsed = JSON.parse(bytes.toString('utf8')) } catch {}
    return { status: response.status, body: parsed, bytes }
  }

  async function waitForCapture(): Promise<any> {
    await vi.waitFor(async () => expect((await request('GET', '/v1/backup')).body.capture).not.toBeNull(), { timeout: 5000 })
    return (await request('GET', '/v1/backup')).body.capture
  }

  beforeEach(async () => {
    root = await mkdtemp(join(tmpdir(), 'caboose-backup-'))
    const helper = join(root, 'caboose-disk')
    await copyFile(fileURLToPath(new URL('./fixtures/caboose-disk.mjs', import.meta.url)), helper)
    await chmod(helper, 0o755)
    // Base: four distinct chunks. Disk: base, a changed chunk, zeros, base again, plus a fifth new chunk.
    base = Buffer.concat([chunk(1), chunk(2), chunk(3), chunk(4)])
    disk = Buffer.concat([chunk(1), chunk('random'), chunk(0), chunk(4), chunk('random')])
    await mkdir(join(root, 'images'))
    await writeFile(join(root, 'images', 'base.raw'), base)
    for (const name of ['vmlinux', 'initrd']) await writeFile(join(root, 'images', name), name)
    await mkdir(join(root, 'overlays'))
    await writeFile(join(root, 'overlays', 'view.raw'), disk)
    binding = null
    lifecycle = new ComputerLifecycle<string>({ wake: async () => 'session', park: async () => {} }, 600_000)
    // macOS has no FICLONE_FORCE through Node; a plain copy stands in for the reflink.
    const host: BackupHost = { helper, imageRoot: join(root, 'images'), cacheDirectory: join(root, 'cache'), unavailable: null, clone: (from, to) => copyFile(from, to) }
    backups = new ComputerBackups(host, {
      id: 'c1', lifecycle, directory: join(root, 'overlays'),
      parkedView: async () => ({ image: join(root, 'overlays', 'view.raw') }),
      binding: async () => binding,
      phoneName: id => id === 'phone-1' ? 'iPhone' : undefined,
    })
    await backups.open()
    server = createServer((req, res) => {
      const path = new URL(req.url ?? '/', 'http://x').pathname
      void (path.startsWith('/v1/recovery') ? recoveryRoute(backups, req, res, path, { kind: 'owner' }, context) : backups.handle(req, res, path, phone, context)).catch(error => {
        const status = error instanceof SettingsInputError ? 400 : error instanceof AgentNotFoundError ? 404 : error instanceof ComputerConflictError ? 409 : 500
        if (status === 500) console.error(error)
        res.writeHead(status, { 'content-type': 'application/json' }).end(JSON.stringify({ error: error.message }))
      })
    })
    await new Promise<void>(resolve => server.listen(0, '127.0.0.1', resolve))
    url = `http://127.0.0.1:${(server.address() as { port: number }).port}`
    restarts.length = 0
  })

  afterEach(async () => {
    backups.close()
    await new Promise(resolve => server.close(resolve))
    await rm(root, { recursive: true, force: true })
  })

  it('binds destructive confirmation to the selected capture', async () => {
    await backups.manageRecovery('capture', context)
    const capture = (await backups.recoveryStatus()).captures[0]!
    expect((await request('POST', `/v1/recovery/captures/${capture.id}/restore`, { confirm: true })).status).toBe(400)
    expect(restarts).toHaveLength(0)
    expect((await request('POST', `/v1/recovery/captures/${capture.id}/restore`, { confirm: capture.id })).status).toBe(200)
    expect(restarts).toHaveLength(1)
  })

  it('manually captures without enrolling a phone and restores verified host data', async () => {
    await backups.manageRecovery('capture', context)
    const status = await backups.recoveryStatus()
    expect(status.captures).toHaveLength(1)
    expect(status.lastOperation?.state).toBe('succeeded')
    expect((await request('GET', '/v1/backup')).body.devices).toEqual([])
    await backups.manageRecovery('restore', context, status.captures[0]!.id)
    expect(restarts[0]!.content.equals(disk)).toBe(true)
  })

  it('rejects running captures and records failure durably', async () => {
    await lifecycle.wake()
    await expect(backups.manageRecovery('capture', context)).rejects.toThrow('Park this computer')
    expect((await backups.recoveryStatus()).lastOperation?.state).toBe('failed')
    expect(JSON.parse(await readFile(join(root, 'overlays', 'c1.backup', 'management.json'), 'utf8')).state).toBe('failed')
    expect((await backups.recoveryStatus()).captures).toEqual([])
  })

  it('rejects overlapping management work and leaves a staged phone restore intact', async () => {
    const first = backups.manageRecovery('capture', context)
    await expect(backups.manageRecovery('capture', context)).rejects.toThrow('already running')
    await first
    const capture = (await backups.recoveryStatus()).captures[0]!
    const { info, manifest } = (await request('GET', `/v1/backup/captures/${capture.id}`)).body
    const stage = await request('POST', '/v1/backup/restores', { image: info.image, manifest })
    await expect(backups.manageRecovery('restore', context, capture.id)).rejects.toThrow('phone restore is staged')
    expect((await request('GET', `/v1/backup/restores/${stage.body.id}`)).status).toBe(200)
    expect(restarts).toHaveLength(0)
  })

  it('does not restart when a captured image dependency changed', async () => {
    await backups.manageRecovery('capture', context)
    await writeFile(join(root, 'images', 'vmlinux'), 'different kernel')
    await expect(backups.manageRecovery('restore', context, (await backups.recoveryStatus()).captures[0]!.id)).rejects.toThrow()
    expect(restarts).toHaveLength(0)
  })

  it('captures a parked computer once a phone turns backups on, describing only its own chunks', async () => {
    expect((await request('GET', '/v1/backup')).body).toMatchObject({ available: true, enabled: false, capture: null })
    expect((await request('PUT', '/v1/backup/device', { enabled: true })).body).toMatchObject({ enabled: true, devices: [{ id: 'phone-1', name: 'iPhone', lastCompletedAt: null }] })
    const capture = await waitForCapture()
    expect(capture).toMatchObject({ diskBytes: 5 * MiB, chunkBytes: MiB, dataChunks: 2, dataBytes: 2 * MiB, image: { baseSha256: createHash('sha256').update(base).digest('hex'), vmlinux: createHash('sha256').update('vmlinux').digest('hex'), initrd: createHash('sha256').update('initrd').digest('hex'), systemErofs: null } })
    const { body } = await request('GET', `/v1/backup/captures/${capture.id}`)
    expect(body.manifest.chunks).toEqual([{ base: 1 }, createHash('sha256').update(disk.subarray(MiB, 2 * MiB)).digest('hex'), { zero: 1 }, { base: 1 }, createHash('sha256').update(disk.subarray(4 * MiB)).digest('hex')])
  })

  it('serves exactly the requested chunks in packs, and records a completed backup', async () => {
    await request('PUT', '/v1/backup/device', { enabled: true })
    const capture = await waitForCapture()
    const manifest = (await request('GET', `/v1/backup/captures/${capture.id}`)).body.manifest
    const wanted = [manifest.chunks[4], manifest.chunks[1]]
    const planned = await request('POST', `/v1/backup/captures/${capture.id}/packs`, { chunks: wanted })
    expect(planned.status).toBe(201)
    expect(planned.body.packs).toEqual([{ id: expect.any(String), chunks: wanted, bytes: 2 * MiB }])
    const pack = await request('GET', `/v1/backup/packs/${planned.body.packs[0].id}`)
    expect(pack.bytes.equals(Buffer.concat([disk.subarray(4 * MiB), disk.subarray(MiB, 2 * MiB)]))).toBe(true)
    expect((await request('POST', `/v1/backup/captures/${capture.id}/packs`, { chunks: ['0'.repeat(64)] })).status).toBe(400)
    const done = await request('POST', '/v1/backup/complete', { capture: capture.id })
    expect(done.body.devices[0].lastCompletedAt).toEqual(expect.any(String))
  })

  it('restores from chunks the host still holds, verifying the rebuilt disk before the restart', async () => {
    await request('PUT', '/v1/backup/device', { enabled: true })
    const capture = await waitForCapture()
    const { manifest, info } = (await request('GET', `/v1/backup/captures/${capture.id}`)).body
    const begun = await request('POST', '/v1/backup/restores', { image: info.image, manifest })
    expect(begun.status).toBe(201)
    expect(begun.body.missing).toEqual([])
    expect((await request('POST', `/v1/backup/restores/${begun.body.id}/apply`, {})).status).toBe(400)
    const applied = await request('POST', `/v1/backup/restores/${begun.body.id}/apply`, { confirm: true })
    expect(applied.status).toBe(200)
    expect(restarts).toHaveLength(1)
    expect(restarts[0]!.binding).toBeNull()
    expect(restarts[0]!.content.equals(disk)).toBe(true)
    expect(await readdir(join(root, 'overlays', 'c1.backup', 'restores'))).toEqual([])
  })

  it('restores on a host without the capture from chunks the phone uploads, rejecting bad ones', async () => {
    await request('PUT', '/v1/backup/device', { enabled: true })
    const capture = await waitForCapture()
    const { manifest, info } = (await request('GET', `/v1/backup/captures/${capture.id}`)).body
    // The host lost its captures.
    await rm(join(root, 'overlays', 'c1.backup', 'captures'), { recursive: true })
    const begun = await request('POST', '/v1/backup/restores', { image: info.image, manifest })
    expect(begun.body.missing.sort()).toEqual([manifest.chunks[1], manifest.chunks[4]].sort())
    const record = (data: Buffer, hash = createHash('sha256').update(data).digest()) => {
      const header = Buffer.alloc(36)
      hash.copy(header)
      header.writeUInt32BE(data.length, 32)
      return Buffer.concat([header, data])
    }
    const wrong = await request('PUT', `/v1/backup/restores/${begun.body.id}/chunks`, undefined, record(chunk(9), Buffer.from(manifest.chunks[1], 'hex')))
    expect(wrong.status).toBe(400)
    expect((await request('POST', `/v1/backup/restores/${begun.body.id}/apply`, { confirm: true })).status).toBe(409)
    const sent = await request('PUT', `/v1/backup/restores/${begun.body.id}/chunks`, undefined, Buffer.concat([record(disk.subarray(MiB, 2 * MiB)), record(disk.subarray(4 * MiB))]))
    expect(sent.body).toEqual({ id: begun.body.id, missing: 0 })
    expect((await request('POST', `/v1/backup/restores/${begun.body.id}/apply`, { confirm: true })).status).toBe(200)
    expect(restarts[0]!.content.equals(disk)).toBe(true)
  })

  it('refuses a backup made with an image this host does not have', async () => {
    const manifest = { version: 1, diskBytes: MiB, chunkBytes: MiB, baseSha256: 'a'.repeat(64), chunks: [{ base: 1 }] }
    const response = await request('POST', '/v1/backup/restores', { image: { baseSha256: 'a'.repeat(64), vmlinux: 'b'.repeat(64), initrd: 'c'.repeat(64), systemErofs: null }, manifest })
    expect(response.status).toBe(409)
    expect(response.body.error).toMatch(/needs the computer image it was made with/)
  })

  it('a split-image backup restores only onto the same kernel, initramfs and system image', async () => {
    await writeFile(join(root, 'images', 'system.erofs'), 'system.erofs')
    const hash = (data: Buffer | string) => createHash('sha256').update(data).digest('hex')
    binding = { version: 1, directory: join(root, 'images'), hashes: { 'base.raw': hash(base), vmlinux: hash('vmlinux'), initrd: hash('initrd'), 'system.erofs': hash('system.erofs') } }
    await request('PUT', '/v1/backup/device', { enabled: true })
    const capture = await waitForCapture()
    expect(capture.image).toMatchObject({ vmlinux: hash('vmlinux'), initrd: hash('initrd'), systemErofs: hash('system.erofs') })
    const { manifest, info } = (await request('GET', `/v1/backup/captures/${capture.id}`)).body
    const other = await request('POST', '/v1/backup/restores', { image: { ...info.image, vmlinux: 'b'.repeat(64) }, manifest })
    expect(other.status).toBe(409)
    const begun = await request('POST', '/v1/backup/restores', { image: info.image, manifest })
    await request('POST', `/v1/backup/restores/${begun.body.id}/apply`, { confirm: true })
    expect(restarts[0]!.binding).toEqual(binding)
  })

  it('does not capture while the computer runs; a requested capture waits for the next park', async () => {
    await lifecycle.wake()
    await request('PUT', '/v1/backup/device', { enabled: true })
    expect((await request('POST', '/v1/backup/capture')).body).toMatchObject({ capture: null, pending: true })
    await lifecycle.park()
    await waitForCapture()
  })
})
