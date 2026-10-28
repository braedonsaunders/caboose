/** Real native host adapter check. Uses a disposable overlay; never edits the base image. */
import assert from 'node:assert/strict'
import { mkdtemp, readFile, rm, symlink, writeFile } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join, resolve } from 'node:path'
import { createVirtualizationBackend, type DeskHandle } from '@braedonsaunders/appkit-desk'
import { config } from '../src/config.js'
import { createController, createDeskPool } from '../src/driver.js'
import { peek } from './display-client.mjs'

if (process.platform !== 'darwin' || process.arch !== 'arm64') throw new Error('Requires Apple Silicon macOS')
const source = process.env.CABOOSE_CHECK_IMAGE_ROOT
const helperPath = process.env.CABOOSE_VMM_PATH
if (!source || !helperPath) throw new Error('Set CABOOSE_CHECK_IMAGE_ROOT and CABOOSE_VMM_PATH')
const directory = await mkdtemp(join(tmpdir(), 'caboose-macos-'))
await writeFile(join(directory, 'console.log'), '')
const backend = createVirtualizationBackend({ helperPath, connectTimeoutMs: 120_000,
  ...(process.env.CABOOSE_CHECK_CONSOLE === '1' ? { consoleLogPath: join(directory, 'console.log') } : {}) })
const settings = config({ CABOOSE_IMAGE_ROOT: directory, CABOOSE_VMM_PATH: helperPath,
  CABOOSE_MEMORY_MB: process.env.CABOOSE_CHECK_MEMORY_MB ?? '1536', CABOOSE_VCPUS: '2', CABOOSE_MAX_RUNNING: '1' })
const desks = createDeskPool(settings, { backend })
let current: DeskHandle | undefined
const originalStart = desks.start.bind(desks)
desks.start = async options => { current = await originalStart(options); return current }
// Collect diagnostics before a failed wake parks the guest.
const originalSuspend = desks.suspend.bind(desks)
desks.suspend = async id => {
  if (current) {
    const result = await current.exec({ command: '/usr/bin/journalctl', args: ['-b', '-n', '40', '--no-pager', '-u', 'caboose-display.service'], timeoutMs: 10_000 }).catch(() => undefined)
    if (result) console.log(result.stdout)
  }
  await originalSuspend(id)
  current = undefined
}
const controller = createController(settings, { backend, desks })
try {
  for (const file of ['base.raw', 'vmlinux', 'initrd']) await symlink(resolve(source, file), join(directory, file))
  let session = await controller.wake()
  assert.equal(session.state, 'running')
  const guest = controller.guest()!
  const boot = await guest.run('/bin/cat', ['/proc/sys/kernel/random/boot_id'])
  const display = await peek(controller.displayUrl, { token: session.display.token, ms: 100 })
  assert(display.features)
  console.log('ok: native controller wake and display hello through loopback relay')
  await guest.run('/bin/sh', ['-c', 'systemctl start caboose-files.service caboose-terminal.service'])
  for (const endpoint of [controller.fileService!(), controller.terminalService!()]) {
    const response = await fetch(endpoint.url + '/health', { signal: AbortSignal.timeout(10_000) })
    await response.body?.cancel()
    assert.equal(response.status, 401, 'Guest service must require the per-wake token')
  }
  console.log('ok: file and terminal loopback relays enforce guest authentication')
  await controller.park()
  assert(controller.hasSavedState())
  session = await controller.wake()
  assert.equal(await controller.guest()!.run('/bin/cat', ['/proc/sys/kernel/random/boot_id']), boot)
  assert.equal(desks.stats().snapshotCpuFallbacks, 0)
  await peek(controller.displayUrl, { token: session.display.token, ms: 100 })
  console.log('ok: memory park/restore keeps the guest boot and restores display relay')
} catch (error) {
  console.error((await readFile(join(directory, 'console.log'), 'utf8').catch(() => '')).slice(-3000))
  throw error
} finally {
  try { await controller.destroy!() } finally { await rm(directory, { recursive: true, force: true }) }
}
