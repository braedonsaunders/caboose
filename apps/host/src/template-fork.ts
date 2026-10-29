import { execFile } from 'node:child_process'
import { promisify } from 'node:util'
import { join } from 'node:path'
import { readFile } from 'node:fs/promises'
import * as desk from '@braedonsaunders/appkit-desk'
import type { DeskLaunchPlan, DeskMachine, DeskReadOnlyAttachment } from '@braedonsaunders/appkit-desk'
import { parseExecResult } from '@braedonsaunders/appkit-desk'
import { buildTemplateSource, type TemplateBuildOptions } from './template-builder.js'
import { networkSlot } from './network.js'
import { templateNetworkFence } from './template-network.js'
import { readBundle } from './components.js'

const exec = promisify(execFile)
interface Compatibility { vmmVersion: string; vmmPath: string; cpuSignature: string; componentVersion: string; baseImagePath: string; kernelPath: string; initramfsPath: string; attachmentPaths: string[] }
interface TemplateApi {
  hostCpuSignature(): Promise<string>
  forkDeskTemplate(snapshot: string, childDirectory: string, identity: { deskId: string; tap: string; mac: string; vsockCid: number; vsockSocket: string }, compatibility: Compatibility): Promise<unknown>
  verifyDeskTemplateFork(childDirectory: string, identity: { deskId: string; tap: string; mac: string; vsockCid: number; vsockSocket: string }, compatibility: Compatibility): Promise<void>
  verifyDeskTemplateCompatibility(childDirectory: string, compatibility: Compatibility): Promise<void>
}
export interface TemplateForkOptions extends TemplateBuildOptions {
  childDirectory: string
  deskId: string
  slot: number
  attachments?: readonly DeskReadOnlyAttachment[]
}

/** Reject changed boot images or device endpoints without discarding saved memory. */
export function assertSavedTemplateConfig(value: unknown, plan: DeskLaunchPlan, kernel: string, initramfs: string, attachments: readonly DeskReadOnlyAttachment[]): void {
  if (plan.hypervisor !== 'cloud-hypervisor' || !value || typeof value !== 'object' || Array.isArray(value)) throw new Error('Invalid parked template configuration')
  const saved = value as { payload?: { kernel?: string; initramfs?: string }; disks?: { path?: string; readonly?: boolean }[]; net?: { tap?: string; mac?: string }[]; vsock?: { cid?: number; socket?: string } }
  if (saved.payload?.kernel !== kernel || saved.payload.initramfs !== initramfs || saved.disks?.length !== attachments.length + 1
    || saved.disks[0]?.path !== plan.overlay.path || saved.disks[0].readonly === true
    || attachments.some((item, index) => saved.disks?.[index + 1]?.path !== item.path || saved.disks?.[index + 1]?.readonly !== true)
    || saved.net?.length !== 1 || saved.net[0]?.tap !== plan.tap.device || saved.net[0].mac?.toLowerCase() !== plan.tap.mac.toLowerCase()
    || saved.vsock?.cid !== plan.vsock.cid || saved.vsock.socket !== plan.vsock.socketPath) throw new Error('Parked template image or device identity does not match')
}

/** Callback set consumed by AppKit before a new template child is exposed. */
export function templateFork(options: TemplateForkOptions) {
  const fence = templateNetworkFence(options.slot)
  const address = networkSlot(options.slot)
  let guest: DeskMachine | undefined
  const command = async (machine: DeskMachine, command: string, args: string[], timeoutMs = 30_000) => {
    const result = parseExecResult(await machine.request({ op: 'exec', command, args, timeoutMs }, { timeoutMs: timeoutMs + 5_000 }))
    if (result.exitCode !== 0 || result.truncated) throw new Error(`Template guest command failed: ${result.stderr || result.exitCode}`)
    return result.stdout
  }
  const compatibility = async (api: Partial<TemplateApi>, componentVersion?: string): Promise<Compatibility> => {
    if (typeof api.hostCpuSignature !== 'function') throw new Error('Template forks require a compatible AppKit desk release')
    const version = (await exec(options.vmmPath, ['--version'], { timeout: 15_000 })).stdout.trim()
    return { vmmVersion: version, vmmPath: options.vmmPath, cpuSignature: await api.hostCpuSignature(), componentVersion: componentVersion ?? (await readBundle()).version, baseImagePath: options.baseImage,
      kernelPath: options.kernel, initramfsPath: options.initramfs, attachmentPaths: (options.attachments ?? []).map(item => item.path) }
  }
  const identity = (plan: DeskLaunchPlan) => {
    if (plan.hypervisor !== 'cloud-hypervisor') throw new Error('Template forks require Cloud Hypervisor')
    return { deskId: options.deskId, tap: plan.tap.device, mac: plan.tap.mac, vsockCid: plan.vsock.cid, vsockSocket: plan.vsock.socketPath }
  }
  return {
    async holdFence(): Promise<void> { await fence.hold() },
    async prepare(plan: DeskLaunchPlan): Promise<void> {
      if (plan.hypervisor !== 'cloud-hypervisor') throw new Error('Template forks require Cloud Hypervisor')
      const api = desk as unknown as Partial<TemplateApi>
      if (typeof api.hostCpuSignature !== 'function' || typeof api.forkDeskTemplate !== 'function') throw new Error('Template forks require an AppKit desk release with template support')
      await buildTemplateSource(options)
      await api.forkDeskTemplate(join(options.directory, 'source.snapshot'), options.childDirectory, identity(plan), await compatibility(api))
    },
    async verifyPrepared(plan: DeskLaunchPlan): Promise<void> {
      const api = desk as unknown as Partial<TemplateApi>
      if (typeof api.verifyDeskTemplateFork !== 'function') throw new Error('Template forks require prepared-state verification')
      await api.verifyDeskTemplateFork(options.childDirectory, identity(plan), await compatibility(api))
    },
    async verifyResume(plan: DeskLaunchPlan): Promise<void> {
      if (plan.hypervisor !== 'cloud-hypervisor') throw new Error('Template forks require Cloud Hypervisor')
      const api = desk as unknown as Partial<TemplateApi>
      if (typeof api.verifyDeskTemplateCompatibility !== 'function') throw new Error('Template resume requires image verification')
      const binding = JSON.parse(await readFile(join(options.childDirectory, '.template-binding.json'), 'utf8')) as { compatibility?: { componentVersion?: unknown } }
      const savedVersion = binding.compatibility?.componentVersion
      if (typeof savedVersion !== 'string' || !savedVersion) throw new Error('Template component identity is missing')
      await api.verifyDeskTemplateCompatibility(options.childDirectory, await compatibility(api, savedVersion))
      const saved: unknown = JSON.parse(await readFile(join(plan.snapshot.dir, 'config.json'), 'utf8'))
      assertSavedTemplateConfig(saved, plan, options.kernel, options.initramfs, options.attachments ?? [])
    },
    async initialize(machine: DeskMachine, plan: DeskLaunchPlan): Promise<void> {
      if (plan.hypervisor !== 'cloud-hypervisor') throw new Error('Template forks require Cloud Hypervisor')
      guest = machine
      const helper = '/usr/local/libexec/caboose-template'
      await command(machine, '/usr/bin/python3', [helper, 'refresh-vsock'])
      const deadline = Date.now() + 60_000
      let ready = false
      while (Date.now() < deadline) {
        await new Promise(resolve => setTimeout(resolve, 500))
        try { await command(machine, '/usr/bin/python3', [helper, 'check-vsock', String(plan.vsock.cid)], 5_000); ready = true; break } catch { /* wait for guest bridge reconnection */ }
      }
      if (!ready) throw new Error('Guest vsock identity did not refresh')
      await command(machine, '/usr/bin/python3', [helper, 'reinitialize', plan.tap.mac, String(plan.vsock.cid)], 90_000)
      const previous = (await command(machine, '/usr/bin/python3', [helper, 'restart-agent'])).trim().split('\n').at(-1) ?? ''
      if (!/^[0-9]+:[0-9]+$/.test(previous)) throw new Error('Could not identify the source guest agent')
      const agentDeadline = Date.now() + 60_000
      let agentReady = false
      while (Date.now() < agentDeadline) {
        await new Promise(resolve => setTimeout(resolve, 500))
        try { await command(machine, '/usr/bin/python3', [helper, 'check-agent', previous], 5_000); agentReady = true; break } catch { /* wait for a new private agent */ }
      }
      if (!agentReady) throw new Error('Private guest agent did not restart')
      const script = `set -eu\ndev=$(ls /sys/class/net | grep -E '^(en|eth)' | head -n 1)\ntest -n "$dev"\nip addr flush dev "$dev"\nip addr add ${address.guest}/30 dev "$dev"\nip link set dev "$dev" up\nip route replace default via ${address.host} dev "$dev"\nrm -f /etc/resolv.conf\nprintf 'nameserver 1.1.1.1\\n' > /etc/resolv.conf\ndate -u -s @${(Date.now() / 1000).toFixed(3)} >/dev/null`
      await command(machine, '/bin/sh', ['-c', script])
    },
    async releaseFence(): Promise<void> {
      if (!guest) throw new Error('Template guest was not initialized')
      await command(guest, '/usr/bin/python3', ['/usr/local/libexec/caboose-template', 'activate'], 90_000)
      await fence.release()
    },
  }
}
