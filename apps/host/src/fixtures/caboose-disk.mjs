#!/usr/bin/env node
// A stand-in for caboose-disk's manifest, base-hash, punch and discard commands in tests on
// machines without Linux's FIEMAP: it reads files in full and prints the same formats.
import { createHash } from 'node:crypto'
import { readFileSync, openSync, writeSync, closeSync } from 'node:fs'

const [command, ...rest] = process.argv.slice(2)
const flag = name => { const at = rest.indexOf(name); return at >= 0 ? rest[at + 1] : undefined }
const sha = bytes => createHash('sha256').update(bytes).digest('hex')
const zero = bytes => bytes.every(byte => byte === 0)

if (command === 'base-hash') {
  const base = readFileSync(flag('--base'))
  process.stdout.write(`${JSON.stringify({ sha256: sha(base), size: base.length })}\n`)
} else if (command === 'manifest') {
  const image = readFileSync(flag('--image'))
  const base = flag('--base') ? readFileSync(flag('--base')) : null
  const chunkBytes = Number(flag('--chunk-bytes') ?? 1048576)
  const chunks = []
  for (let offset = 0; offset < image.length; offset += chunkBytes) {
    const bytes = image.subarray(offset, Math.min(offset + chunkBytes, image.length))
    if (zero(bytes)) chunks.push('zero')
    else if (base && offset + bytes.length <= base.length && base.subarray(offset, offset + bytes.length).equals(bytes)) chunks.push('base')
    else chunks.push(sha(bytes))
  }
  const entries = []
  for (const chunk of chunks) {
    const last = entries.at(-1)
    if (chunk === 'zero' || chunk === 'base') {
      if (last && typeof last === 'object' && chunk in last) last[chunk]++
      else entries.push({ [chunk]: 1 })
    } else entries.push(chunk)
  }
  process.stdout.write(`${JSON.stringify({ version: 1, diskBytes: image.length, chunkBytes, baseSha256: base ? sha(base) : null, chunks: entries })}\n`)
} else if (command === 'punch' || command === 'discard') {
  const file = rest[0]
  const content = readFileSync(file)
  const fd = openSync(file, 'r+')
  for (const line of readFileSync(0, 'utf8').split('\n').filter(Boolean)) {
    const [offset, length] = line.split(' ').map(Number)
    if (command === 'punch' && !zero(content.subarray(offset, offset + length))) { process.stderr.write('caboose-disk: range holds data\n'); process.exit(1) }
    writeSync(fd, Buffer.alloc(length), 0, length, offset)
  }
  closeSync(fd)
} else {
  process.stderr.write(`caboose-disk: unsupported in the test stand-in: ${command}\n`)
  process.exit(2)
}
