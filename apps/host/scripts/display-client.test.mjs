import { readFileSync, readdirSync } from 'node:fs'
import { describe, expect, it } from 'vitest'
import { Float, decode, frame, reader } from './display-client.mjs'

const VECTORS = new URL('../../../guest/display/vectors/', import.meta.url)

/** Typed vector JSON ({"$float"}, {"$bytes"}) to what the client encodes and decodes. */
function typed(value, floats) {
  if (Array.isArray(value)) return value.map(item => typed(item, floats))
  if (value && typeof value === 'object') {
    if ('$float' in value) return floats ? new Float(value.$float) : value.$float
    if ('$bytes' in value) return Buffer.from(value.$bytes, 'hex')
    return Object.fromEntries(Object.entries(value).map(([k, v]) => [k, typed(v, floats)]))
  }
  return value
}

const canonical = readdirSync(VECTORS).filter(name => name.endsWith('.json')).map(name => JSON.parse(readFileSync(new URL(name, VECTORS), 'utf8')))
  .filter(vector => vector.messages.every(message => message.fields && !message.payload_hex && !message.equivalent_to))

describe('the check client speaks the Caboose Display Protocol vectors', () => {
  it('has canonical vectors to replay', () => expect(canonical.length).toBeGreaterThan(20))
  for (const vector of canonical) {
    it(`${vector.name}: encodes byte for byte and decodes back`, () => {
      const encoded = Buffer.concat(vector.messages.map(message => frame(message.type_id, typed(message.fields, true))))
      expect(encoded.toString('hex')).toBe(vector.hex)
      const decoded = reader()(Buffer.from(vector.hex, 'hex'))
      expect(decoded.map(message => message.type)).toEqual(vector.messages.map(message => message.type_id))
      decoded.forEach((message, i) => expect(message.fields).toEqual(typed(vector.messages[i].fields, false)))
    })
  }
  it('reads a message split across chunks', () => {
    const bytes = frame(0x04, { id: 7 })
    const read = reader()
    expect(read(bytes.subarray(0, 3))).toEqual([])
    expect(read(bytes.subarray(3))).toEqual([{ type: 0x04, fields: { id: 7 } }])
  })
  it('decodes half and single precision floats', () => {
    expect(decode(Buffer.from('f93e00', 'hex'))[0]).toBe(1.5)
    expect(decode(Buffer.from('fa3fc00000', 'hex'))[0]).toBe(1.5)
  })
})
