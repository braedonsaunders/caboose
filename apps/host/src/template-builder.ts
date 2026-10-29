import { randomInt, randomUUID } from 'node:crypto'
import { execFile } from 'node:child_process'
import { chmod, mkdir, mkdtemp, open, rm } from 'node:fs/promises'
import { existsSync } from 'node:fs'
import { dirname, join, isAbsolute } from 'node:path'
import { promisify } from 'node:util'
import * as desk from '@braedonsaunders/appkit-desk'
import type { DeskHandle, DeskReadOnlyAttachment } from '@braedonsaunders/appkit-desk'
import { templateNetworkFenceForTap } from './template-network.js'
import { readBundle } from './components.js'

const exec = promisify(execFile)
interface Compatibility {
  vmmVersion: string; vmmPath: string; cpuSignature: string; componentVersion: string; baseImagePath: string; kernelPath: string; initramfsPath: string; attachmentPaths: string[]
}
interface TemplateApi {
  DESK_TEMPLATE_VERSION: number
  hostCpuSignature(): Promise<string>
  registerDeskTemplate(snapshot: string, disk: string, compatibility: Compatibility): Promise<void>
}
export interface TemplateBuildOptions {
  directory: string
  baseImage: string
  kernel: string
  initramfs: string
  vmmPath: string
  memoryMb: number
  vcpus: number
  freePageReporting?: boolean
  attachments?: readonly DeskReadOnlyAttachment[]
}
async function privileged(command: string, args: string[]): Promise<void> {
  const root = process.getuid?.() === 0
  await exec(root ? command : 'sudo', root ? args : ['-n', command, ...args], { timeout: 15_000 })
}

/** Only the tested official and incremental builds have template support. */
export function supportedTemplateVmm(version: string): boolean {
  return ['cloud-hypervisor v54.0', 'cloud-hypervisor v54.0.0-appkit-incremental.1'].includes(version)
}

/** Reject a guest image that does not contain the complete current bundle. */
export async function verifyTemplateGuestComponents(source: Pick<DeskHandle, 'exec'>, expectedComponents: string): Promise<void> {
  const versionCheck = await source.exec({ command: '/bin/cat', args: ['/usr/local/share/caboose/components.version'], timeoutMs: 15_000 })
  if (versionCheck.exitCode !== 0 || versionCheck.truncated || versionCheck.stdout.trim() !== expectedComponents) throw new Error('Golden image does not contain the current complete Caboose component bundle')
  const required = await source.exec({ command: '/bin/sh', args: ['-c', 'set -eu; for unit in desk-guest-agent.service desk-vsock-bridge.service caboose-vsock-services.service caboose-files.service caboose-terminal.service caboose-template.target; do systemctl cat "$unit" >/dev/null; done; test -f /opt/caboose/files/caboose-files.py; test -f /opt/caboose/terminal/caboose-terminal.py; test -f /opt/caboose/vsock/caboose-vsock-services.py; test -f /usr/local/libexec/caboose-template'], timeoutMs: 30_000 })
  if (required.exitCode !== 0 || required.truncated) throw new Error('Golden image is missing a required template service or helper')
}

const sourceBuilds = new Map<string, Promise<void>>()

/** Build only from the golden image into a new private, non-user VM directory. */
export function buildTemplateSource(options: TemplateBuildOptions): Promise<void> {
  const pending = sourceBuilds.get(options.directory)
  if (pending) return pending
  const work = buildTemplateSourceOnce(options)
  sourceBuilds.set(options.directory, work)
  const clear = () => { if (sourceBuilds.get(options.directory) === work) sourceBuilds.delete(options.directory) }
  void work.then(clear, clear)
  return work
}

async function buildTemplateSourceOnce(options: TemplateBuildOptions): Promise<void> {
  for (const path of [options.directory, options.baseImage, options.kernel, options.initramfs, options.vmmPath]) {
    if (!isAbsolute(path)) throw new Error('Template builder requires absolute paths')
  }
  if (options.attachments?.some(item => item.kind !== 'block')) throw new Error('Templates support read-only block attachments only')
  const api = desk as unknown as Partial<TemplateApi>
  if (api.DESK_TEMPLATE_VERSION !== 3 || typeof api.hostCpuSignature !== 'function' || typeof api.registerDeskTemplate !== 'function') throw new Error('Template building requires an AppKit desk release with template registration')
  const version = (await exec(options.vmmPath, ['--version'], { timeout: 15_000 })).stdout.trim()
  if (!supportedTemplateVmm(version)) throw new Error('Templates require a supported Cloud Hypervisor v54 build')
  const expectedComponents = (await readBundle()).version
  const snapshot = join(options.directory, 'source.snapshot'), disk = join(options.directory, 'source.raw')
  const readyPath = join(options.directory, '.ready')
  if (existsSync(readyPath)) {
    if (existsSync(join(options.directory, '.build.json'))) throw new Error('Template source cleanup was interrupted; operator recovery is required')
    return
  }
  // A prior incomplete directory is retained for recovery and cannot be reused.
  await mkdir(options.directory, { mode: 0o700 })
  const runtimeParent = join(dirname(dirname(options.directory)), 'runtime')
  await mkdir(runtimeParent, { recursive: true, mode: 0o700 })
  const runtime = await mkdtemp(join(runtimeParent, 'tpl-'))
  const tap = `dsk${randomInt(100000000, 999999999)}`
  const receipt = await open(join(options.directory, '.build.json'), 'wx', 0o600)
  try { await receipt.writeFile(JSON.stringify({ version: 1, tap, runtime, vmmPath: options.vmmPath })); await receipt.sync() } finally { await receipt.close() }
  const sourceDirectory = await open(options.directory, 'r')
  try { await sourceDirectory.sync() } finally { await sourceDirectory.close() }
  const alias = `caboose-template-${randomUUID()}`
  const fence = templateNetworkFenceForTap(tap)
  let tapOwned = false, stopped = true
  const host = desk.createDeskHost({ imageRoot: options.directory, runtimeDir: runtime, vmmPath: options.vmmPath,
    kernelCmdline: 'root=/dev/vda3 rw caboose.template=1 systemd.unit=caboose-template.target',
    initramfsPath: options.initramfs, parkWithMemory: true, trimOnSuspend: false, capacity: 1, cidBase: 0xffffff00,
    ports: { onEvent: () => {}, audit: () => {} } })
  try {
    const uid = process.getuid?.()
    if (uid === undefined) throw new Error('Template building requires Linux')
    // Add is exclusive: never adopt or delete an existing TAP.
    await privileged('ip', ['tuntap', 'add', 'dev', tap, 'mode', 'tap', 'user', String(uid)])
    tapOwned = true
    await privileged('ip', ['link', 'set', 'dev', tap, 'alias', alias])
    const root = process.getuid?.() === 0
    const link = await exec(root ? 'ip' : 'sudo', root ? ['-j', 'link', 'show', 'dev', tap] : ['-n', 'ip', '-j', 'link', 'show', 'dev', tap], { timeout: 15_000 })
    const links: unknown = JSON.parse(link.stdout)
    const index = Array.isArray(links) && links.length === 1 ? Number((links[0] as { ifindex?: unknown }).ifindex) : NaN
    if (!Number.isSafeInteger(index) || index < 1) throw new Error('Cannot identify the template TAP')
    const ownership = await open(join(options.directory, '.tap-owner.json'), 'wx', 0o600)
    try { await ownership.writeFile(JSON.stringify({ version: 1, tap, alias, ifindex: index })); await ownership.sync() } finally { await ownership.close() }
    const sourceDir = await open(options.directory, 'r')
    try { await sourceDir.sync() } finally { await sourceDir.close() }
    await fence.hold()
    await privileged('ip', ['link', 'set', 'dev', tap, 'up'])
    stopped = false
    const source = await host.start({ deskId: 'source', baseImage: options.baseImage, overlayPath: disk,
      kernelPath: options.kernel, initramfsPath: options.initramfs, memoryMb: options.memoryMb, vcpus: options.vcpus, freePageReporting: options.freePageReporting,
      network: { tapDevice: tap }, readOnlyAttachments: options.attachments })
    await verifyTemplateGuestComponents(source, expectedComponents)
    const result = await source.exec({ command: '/usr/bin/python3', args: ['/usr/local/libexec/caboose-template', 'prepare'], timeoutMs: 90_000 })
    if (result.exitCode !== 0 || result.truncated) throw new Error(`Template guest isolation failed: ${result.stderr}`)
    await host.suspend('source')
    stopped = true
    for (const file of [disk, ...['config.json', 'state.json', 'memory-ranges'].map(name => join(snapshot, name))]) await chmod(file, 0o400)
    await api.registerDeskTemplate(snapshot, disk, { vmmVersion: version, vmmPath: options.vmmPath, cpuSignature: await api.hostCpuSignature(), componentVersion: expectedComponents,
      baseImagePath: options.baseImage, kernelPath: options.kernel, initramfsPath: options.initramfs,
      attachmentPaths: (options.attachments ?? []).map(item => item.path) })
    const marker = await open(readyPath, 'wx', 0o600)
    try { await marker.writeFile('1\n'); await marker.sync() } finally { await marker.close() }
    const directory = await open(options.directory, 'r')
    try { await directory.sync() } finally { await directory.close() }
  } finally {
    if (!stopped) {
      await host.shutdown('source')
      stopped = true
    }
    // Never remove the fence or TAP if the source could still be running.
    if (tapOwned && stopped) {
      await fence.release()
      await privileged('ip', ['link', 'del', 'dev', tap])
    }
    if (stopped) {
      await rm(runtime, { recursive: true, force: true })
      await rm(join(options.directory, '.tap-owner.json'), { force: true })
      await rm(join(options.directory, '.build.json'), { force: true })
      const directory = await open(options.directory, 'r')
      try { await directory.sync() } finally { await directory.close() }
    }
  }
}
