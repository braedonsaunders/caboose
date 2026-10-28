import { spawn } from 'node:child_process'
import { createHash } from 'node:crypto'
import { constants } from 'node:fs'
import { access, open, rename, rm } from 'node:fs/promises'
import { join } from 'node:path'
import { Readable, Transform, Writable } from 'node:stream'
import { pipeline } from 'node:stream/promises'
import type { ReadableStream as WebReadableStream } from 'node:stream/web'
import { createZstdDecompress } from 'node:zlib'

/**
 * The computer's image, fetched on first run so a new host needs no image build
 * (docs/architecture.md, "Images").
 *
 * microVM: an OCI artifact whose layers are `base.raw.zst`, `vmlinux` and `initrd`, each
 * named by its `org.opencontainers.image.title` annotation. Every blob is checked against
 * its digest as it streams, and the raw disk is written sparse.
 * Container: `docker pull` of the configured image when it is not present.
 */
export interface ImageStatus {
  state: 'ready' | 'fetching' | 'failed' | 'missing'
  /** The registry reference being fetched, or null when the host was given no reference. */
  reference: string | null
  receivedBytes?: number
  totalBytes?: number
  message?: string
}

export interface ImageProvisioner {
  status(): ImageStatus
  /** Starts fetching if needed; resolves when the image is present, or throws with why not. */
  ensure(): Promise<void>
}

export const MICROVM_FILES = ['base.raw', 'vmlinux', 'initrd'] as const
const TITLE = 'org.opencontainers.image.title'
const OCI_MANIFEST = 'application/vnd.oci.image.manifest.v1+json'

export interface OciReference { registry: string; repository: string; reference: string }

/** `registry/repository[:tag][@sha256:…]`; the registry must be explicit. A digest wins over a tag. */
export function parseReference(value: string): OciReference {
  const at = value.indexOf('@')
  const name = at >= 0 ? value.slice(0, at) : value
  const digest = at >= 0 ? value.slice(at + 1) : undefined
  if (digest !== undefined && !/^sha256:[0-9a-f]{64}$/.test(digest)) throw new Error(`Invalid image digest in ${value}`)
  const slash = name.indexOf('/')
  const registry = slash > 0 ? name.slice(0, slash) : ''
  if (!registry || (!/[.:]/.test(registry) && registry !== 'localhost')) throw new Error(`Image reference ${value} must name its registry, like ghcr.io/owner/name:tag`)
  let repository = name.slice(slash + 1)
  let tag = 'latest'
  const colon = repository.lastIndexOf(':')
  if (colon > 0) { tag = repository.slice(colon + 1); repository = repository.slice(0, colon) }
  if (!/^[a-z0-9]+([._-][a-z0-9]+)*(\/[a-z0-9]+([._-][a-z0-9]+)*)*$/.test(repository)) throw new Error(`Invalid repository in ${value}`)
  if (!/^[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}$/.test(tag)) throw new Error(`Invalid tag in ${value}`)
  return { registry, repository, reference: digest ?? tag }
}

interface Layer { mediaType: string; digest: string; size: number; annotations?: Record<string, string> }

/** A registry client for public, anonymously pullable repositories (OCI distribution spec). */
export class Registry {
  private token: string | undefined

  constructor(private readonly ref: OciReference, private readonly fetchImpl: typeof fetch = fetch) {}

  private url(path: string): string {
    const scheme = this.ref.registry.startsWith('localhost') || this.ref.registry.startsWith('127.0.0.1') ? 'http' : 'https'
    return `${scheme}://${this.ref.registry}/v2/${this.ref.repository}/${path}`
  }

  private async get(path: string, accept?: string): Promise<Response> {
    const request = () => this.fetchImpl(this.url(path), {
      headers: { ...(accept ? { accept } : {}), ...(this.token ? { authorization: `Bearer ${this.token}` } : {}) },
    })
    let response = await request()
    if (response.status === 401 && !this.token) {
      await response.body?.cancel()
      this.token = await this.anonymousToken(response.headers.get('www-authenticate'))
      response = await request()
    }
    if (!response.ok) {
      await response.body?.cancel()
      throw new Error(`${this.ref.registry} answered ${response.status} for ${this.ref.repository}`)
    }
    return response
  }

  /** The bearer token a registry hands anonymous pulls (`WWW-Authenticate: Bearer realm=…`). */
  private async anonymousToken(challenge: string | null): Promise<string> {
    const fields = Object.fromEntries([...(challenge ?? '').matchAll(/(\w+)="([^"]*)"/g)].map(match => [match[1]!, match[2]!]))
    if (!/^Bearer /i.test(challenge ?? '') || !fields.realm) throw new Error(`${this.ref.registry} requires credentials`)
    const realm = new URL(fields.realm)
    if (fields.service) realm.searchParams.set('service', fields.service)
    realm.searchParams.set('scope', fields.scope ?? `repository:${this.ref.repository}:pull`)
    const response = await this.fetchImpl(realm)
    if (!response.ok) throw new Error(`${this.ref.registry} refused an anonymous pull (${response.status})`)
    const body = await response.json() as { token?: string; access_token?: string }
    const token = body.token ?? body.access_token
    if (!token) throw new Error(`${this.ref.registry} returned no pull token`)
    return token
  }

  async layers(): Promise<Layer[]> {
    const response = await this.get(`manifests/${this.ref.reference}`, OCI_MANIFEST)
    const bytes = Buffer.from(await response.arrayBuffer())
    if (this.ref.reference.startsWith('sha256:')) verify(this.ref.reference, createHash('sha256').update(bytes).digest('hex'), 'manifest')
    const manifest = JSON.parse(bytes.toString('utf8')) as { mediaType?: string; layers?: Layer[] }
    if (!Array.isArray(manifest.layers)) throw new Error('The image manifest lists no layers')
    return manifest.layers
  }

  async blob(digest: string): Promise<Readable> {
    const response = await this.get(`blobs/${digest}`)
    if (!response.body) throw new Error(`Empty blob ${digest}`)
    return Readable.fromWeb(response.body as WebReadableStream<Uint8Array>)
  }
}

function verify(expected: string, actualHex: string, what: string): void {
  if (expected !== `sha256:${actualHex}`) throw new Error(`The downloaded ${what} does not match its digest`)
}

const BLOCK = 64 * 1024
const ZEROES = Buffer.alloc(BLOCK)

/**
 * Writes a stream to a file, seeking over whole zero blocks instead of writing them, so a
 * mostly-empty raw disk costs only the space its data uses. The final size is set at the end.
 */
export async function sparseWriter(path: string): Promise<Writable> {
  const file = await open(path, 'w', 0o644)
  let position = 0
  let pending: Buffer = Buffer.alloc(0)
  const flush = async (final: boolean) => {
    let offset = 0
    while (pending.length - offset >= BLOCK || (final && offset < pending.length)) {
      const block = pending.subarray(offset, Math.min(offset + BLOCK, pending.length))
      if (!(block.length === BLOCK && block.equals(ZEROES))) await file.write(block, 0, block.length, position)
      position += block.length
      offset += block.length
    }
    pending = pending.subarray(offset)
  }
  return new Writable({
    write(chunk: Buffer, _encoding, done) {
      pending = pending.length ? Buffer.concat([pending, chunk]) : chunk
      flush(false).then(() => done(), done)
    },
    final(done) {
      flush(true).then(() => file.truncate(position)).then(() => file.sync()).then(() => file.close()).then(() => done(), done)
    },
    destroy(error, done) {
      file.close().then(() => done(error), () => done(error))
    },
  })
}

export interface MicrovmImageOptions {
  imageRoot: string
  reference: string | null
  fetch?: typeof fetch
}

export function microvmImage(options: MicrovmImageOptions): ImageProvisioner {
  let status: ImageStatus = { state: 'missing', reference: options.reference }
  let running: Promise<void> | undefined

  const present = async () => {
    try {
      await Promise.all(MICROVM_FILES.map(file => access(join(options.imageRoot, file), constants.R_OK)))
      return true
    } catch {
      return false
    }
  }

  async function fetchAll(reference: string): Promise<void> {
    const registry = new Registry(parseReference(reference), options.fetch)
    const layers = await registry.layers()
    const wanted = MICROVM_FILES.map(file => {
      const layer = layers.find(entry => entry.annotations?.[TITLE] === file || entry.annotations?.[TITLE] === `${file}.zst`)
      if (!layer) throw new Error(`The image has no ${file}`)
      if (!/^sha256:[0-9a-f]{64}$/.test(layer.digest)) throw new Error(`The image's ${file} has an unsupported digest`)
      return { file, layer, compressed: layer.annotations?.[TITLE]?.endsWith('.zst') ?? false }
    })
    status = { state: 'fetching', reference, receivedBytes: 0, totalBytes: wanted.reduce((sum, entry) => sum + entry.layer.size, 0) }
    for (const { file, layer, compressed } of wanted) {
      const target = join(options.imageRoot, file)
      const partial = `${target}.part`
      if (await access(target, constants.R_OK).then(() => true, () => false)) {
        status = { ...status, receivedBytes: (status.receivedBytes ?? 0) + layer.size }
        continue
      }
      const hash = createHash('sha256')
      const counted = new Transform({
        transform(chunk: Buffer, _encoding, done) {
          hash.update(chunk)
          status = { ...status, receivedBytes: (status.receivedBytes ?? 0) + chunk.length }
          done(null, chunk)
        },
      })
      try {
        const source = await registry.blob(layer.digest)
        const output = await sparseWriter(partial)
        if (compressed) await pipeline(source, counted, createZstdDecompress(), output)
        else await pipeline(source, counted, output)
        verify(layer.digest, hash.digest('hex'), file)
        await rename(partial, target)
      } catch (error) {
        await rm(partial, { force: true })
        throw error
      }
    }
  }

  return {
    status: () => status,
    async ensure() {
      if (status.state === 'ready') return
      if (!running) {
        running = (async () => {
          if (await present()) { status = { state: 'ready', reference: options.reference }; return }
          if (!options.reference) { status = { state: 'missing', reference: null }; return }
          try {
            await fetchAll(options.reference)
            status = { state: 'ready', reference: options.reference }
          } catch (error) {
            status = { state: 'failed', reference: options.reference, message: error instanceof Error ? error.message : String(error) }
          }
        })().finally(() => { running = undefined })
      }
      await running
      if (status.state === 'failed') throw new Error(`Downloading the computer's image failed: ${status.message}`)
    },
  }
}

export interface ContainerImageOptions {
  image: string
  /** Runs `docker` with arguments; resolves on exit 0 and rejects with its error output otherwise. */
  docker?: (args: string[]) => Promise<void>
}

/** Pulls the computer's container image when Docker does not have it and it names a registry. */
export function containerImage(options: ContainerImageOptions): ImageProvisioner {
  const docker = options.docker ?? runDocker
  const pullable = options.image.includes('/')
  let status: ImageStatus = { state: 'missing', reference: pullable ? options.image : null }
  let running: Promise<void> | undefined
  return {
    status: () => status,
    async ensure() {
      if (status.state === 'ready') return
      if (!running) {
        running = (async () => {
          if (await docker(['image', 'inspect', options.image]).then(() => true, () => false)) {
            status = { state: 'ready', reference: status.reference }
            return
          }
          if (!pullable) { status = { state: 'missing', reference: null }; return }
          status = { state: 'fetching', reference: options.image }
          try {
            await docker(['pull', '--quiet', options.image])
            status = { state: 'ready', reference: options.image }
          } catch (error) {
            status = { state: 'failed', reference: options.image, message: error instanceof Error ? error.message : String(error) }
          }
        })().finally(() => { running = undefined })
      }
      await running
      if (status.state === 'failed') throw new Error(`Downloading the computer's image failed: ${status.message}`)
    },
  }
}

function runDocker(args: string[]): Promise<void> {
  return new Promise((resolve, reject) => {
    const child = spawn('docker', args, { stdio: ['ignore', 'ignore', 'pipe'] })
    let error = ''
    child.stderr.on('data', (chunk: Buffer) => { error = (error + chunk.toString('utf8')).slice(-2000) })
    child.on('error', reject)
    child.on('close', code => code === 0 ? resolve() : reject(new Error(error.trim() || `docker ${args[0]} exited with ${code}`)))
  })
}

/** A short line for an owner: "Downloading the computer's image (42%)". */
export function describeImage(status: ImageStatus): string {
  switch (status.state) {
    case 'ready': return "The computer's image is ready"
    case 'missing': return "The computer's image is not installed"
    case 'failed': return `Downloading the computer's image failed: ${status.message ?? 'unknown error'}`
    case 'fetching': {
      const percent = status.totalBytes ? Math.floor(((status.receivedBytes ?? 0) / status.totalBytes) * 100) : undefined
      return percent === undefined ? "Downloading the computer's image" : `Downloading the computer's image (${percent}%)`
    }
  }
}
