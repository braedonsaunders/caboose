#!/usr/bin/env node
// Run against a disposable directory on the configured computer. Deletion goes to Trash.
import { randomUUID } from 'node:crypto'
const base = process.env.CABOOSE_URL
const token = process.env.CABOOSE_OWNER_TOKEN
if (!base || !token) throw new Error('Set CABOOSE_URL and CABOOSE_OWNER_TOKEN')
const dir = `caboose-fs-check-${randomUUID()}`
const root = new URL('/v1/fs/', base)
async function call(method, operation, path, body, extra = {}) {
  const url = new URL(operation, root)
  url.searchParams.set('path', path)
  const response = await fetch(url, { method, headers: { authorization: `Bearer ${token}`, ...extra }, body })
  if (!response.ok) throw new Error(`${method} ${operation}: ${response.status} ${await response.text()}`)
  return response
}
try {
  await call('POST', 'mkdir', dir)
  const payload = Buffer.from('Caboose streaming file check\n')
  await call('PUT', 'content', `${dir}/before.txt`, payload, { 'if-none-match': '*' })
  const listing = await (await call('GET', 'list', dir)).json()
  if (!listing.items.some(item => item.name === 'before.txt' && item.size === payload.length)) throw new Error('upload missing from list')
  const range = await call('GET', 'content', `${dir}/before.txt`, undefined, { range: 'bytes=2-7' })
  if (range.status !== 206 || !Buffer.from(await range.arrayBuffer()).equals(payload.subarray(2, 8))) throw new Error('range mismatch')
  await call('POST', 'move', `${dir}/before.txt`, JSON.stringify({ destination: `${dir}/after.txt` }), { 'content-type': 'application/json' })
  await call('DELETE', 'item', `${dir}/after.txt`)
  console.log('Upload, list, range, move and Trash checks passed')
} finally {
  await call('DELETE', 'item', dir).catch(error => console.error('Could not trash check directory:', error.message))
}
