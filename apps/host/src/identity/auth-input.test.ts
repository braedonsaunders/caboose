import { expect, it } from 'vitest'
import { readAuthObject } from './auth-input.js'
const request = (body: string) => new Request('https://example.test/', { method: 'POST', body })
it('rejects malformed and non-object JSON without echoing secrets', async () => {
  for (const body of ['{secret-value', 'null', '[]', '"secret-value"']) {
    await expect(readAuthObject(request(body))).rejects.toMatchObject({ status: 400, message: 'Request body must be a JSON object' })
  }
  expect(await readAuthObject(request('{"id":"session"}'))).toEqual({ id: 'session' })
})
it('counts actual bytes rather than trusting Content-Length', async () => {
  const input = request(JSON.stringify({ value: 'a'.repeat(64 * 1024) }))
  input.headers.set('content-length', '1')
  await expect(readAuthObject(input)).rejects.toMatchObject({ status: 413 })
  const boundary = JSON.stringify({ value: 'a'.repeat(64 * 1024 - 12) })
  expect(Buffer.byteLength(boundary)).toBe(64 * 1024)
  expect(await readAuthObject(request(boundary))).toHaveProperty('value')
})
