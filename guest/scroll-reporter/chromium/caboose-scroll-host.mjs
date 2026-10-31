#!/usr/bin/env node
// Native messaging host com.caboose.scroll (no dependencies). Chromium starts it for the
// Caboose scroll reporter extension; it joins the extension to caboose-display's scroll
// socket. Both sides frame each message as a 32-bit little-endian length then UTF-8 JSON,
// so it passes whole messages through unchanged. While the socket is away (caboose-display
// restarting) it drops reports, tells the extension `unbind`, and reconnects every second.
import { connect } from 'node:net'
import { join } from 'node:path'

const MAX_MESSAGE = 1024 * 1024
const log = message => process.stderr.write(`caboose-scroll-host: ${message}\n`)
const runtime = process.env.XDG_RUNTIME_DIR || `/run/user/${process.getuid()}`
const path = process.env.CABOOSE_SCROLL_SOCKET
  || join(runtime, 'caboose-display', process.env.WAYLAND_DISPLAY || 'wayland-caboose-0', 'scroll.sock')

/** Splits a byte stream into whole messages (length prefix included). */
function framer(onMessage) {
  let buffer = Buffer.alloc(0)
  return chunk => {
    buffer = Buffer.concat([buffer, chunk])
    while (buffer.length >= 4) {
      const length = buffer.readUInt32LE(0)
      if (length > MAX_MESSAGE) {
        log(`a ${length} byte message; closing`)
        process.exit(1)
      }
      if (buffer.length < 4 + length) break
      onMessage(buffer.subarray(0, 4 + length))
      buffer = buffer.subarray(4 + length)
    }
  }
}

const unbind = (() => {
  const body = Buffer.from(JSON.stringify({ type: 'unbind' }))
  const head = Buffer.alloc(4)
  head.writeUInt32LE(body.length)
  return Buffer.concat([head, body])
})()

let socket = null
function open() {
  const s = connect(path)
  s.on('connect', () => {
    socket = s
  })
  s.on('data', framer(message => process.stdout.write(message)))
  s.on('error', () => {})
  s.on('close', () => {
    if (socket === s) {
      socket = null
      process.stdout.write(unbind)
    }
    setTimeout(open, 1000)
  })
}

process.stdin.on('data', framer(message => socket?.write(message)))
// Chromium closes stdin when the extension disconnects.
process.stdin.on('end', () => process.exit(0))
open()
