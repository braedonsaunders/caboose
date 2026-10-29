import { createServer } from 'node:http'
import { randomBytes } from 'node:crypto'
import { mkdtemp, mkdir, readFile, rm, writeFile } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { createStorage } from '@braedonsaunders/appkit-storage'
import { expect, it } from 'vitest'
import { SnapshotTier } from './snapshot-tier.js'

it('round-trips encrypted cold memory through the S3 client and removes its objects', async () => {
  const parts = new Map<string, Buffer>(), objects = new Map<string, Buffer>()
  const tags: string[] = []
  const server = createServer(async (request, response) => {
    const url = new URL(request.url ?? '/', 'http://localhost')
    const key = decodeURIComponent(url.pathname.replace(/^\/bucket\//, ''))
    const chunks: Buffer[] = []
    for await (const chunk of request) chunks.push(Buffer.from(chunk))
    const body = Buffer.concat(chunks)
    if (request.headers['x-amz-tagging']) tags.push(String(request.headers['x-amz-tagging']))
    if (request.method === 'POST' && url.searchParams.has('uploads')) {
      response.setHeader('content-type', 'application/xml')
      response.end('<InitiateMultipartUploadResult><UploadId>upload</UploadId></InitiateMultipartUploadResult>')
    } else if (request.method === 'PUT' && url.searchParams.has('partNumber')) {
      parts.set(key, body); response.setHeader('etag', '"part"'); response.end()
    } else if (request.method === 'POST' && url.searchParams.has('uploadId')) {
      objects.set(key, parts.get(key) ?? Buffer.alloc(0)); response.setHeader('content-type', 'application/xml')
      response.end('<CompleteMultipartUploadResult><ETag>"done"</ETag></CompleteMultipartUploadResult>')
    } else if (request.method === 'GET') {
      const object = objects.get(key)
      if (!object) { response.statusCode = 404; response.end(); return }
      response.end(object)
    } else if (request.method === 'DELETE') { objects.delete(key); response.statusCode = 204; response.end() }
    else { response.statusCode = 400; response.end('unexpected request') }
  })
  await new Promise<void>(resolve => server.listen(0, '127.0.0.1', resolve))
  const address = server.address()
  if (!address || typeof address === 'string') throw new Error('No test listener')
  const root = await mkdtemp(join(tmpdir(), 'snapshot-s3-')), snapshot = join(root, 'owner.snapshot')
  const store = createStorage({ endpoint: `http://127.0.0.1:${address.port}`, bucket: 'bucket', accessKeyId: 'test', secretAccessKey: 'test' })
  const tier = new SnapshotTier(snapshot, store, randomBytes(32), async work => work(1), () => true)
  try {
    await mkdir(snapshot); await writeFile(join(snapshot, 'memory-ranges'), 'private memory')
    await tier.archive(); expect(objects.size).toBe(1)
    await tier.restoreForWake()
    expect(await readFile(join(snapshot, 'memory-ranges'), 'utf8')).toBe('private memory')
    await tier.drainCleanup(); expect(objects.size).toBe(0)
    expect(tags).toEqual([])
  } finally {
    store.client.destroy()
    server.closeAllConnections()
    await new Promise<void>(resolve => server.close(() => resolve()))
    await rm(root, { recursive: true, force: true })
  }
})
