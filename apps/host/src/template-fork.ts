import { execFile } from 'node:child_process'
import { promisify } from 'node:util'
import { join } from 'node:path'
import * as desk from '@braedonsaunders/appkit-desk'
import type { DeskLaunchPlan, DeskMachine, DeskReadOnlyAttachment } from '@braedonsaunders/appkit-desk'
import { parseExecResult } from '@braedonsaunders/appkit-desk'
import { buildTemplateSource, type TemplateBuildOptions } from './template-builder.js'
import { networkSlot } from './network.js'
import { templateNetworkFence } from './template-network.js'

const exec = promisify(execFile)
interface Compatibility { vmmVersion: string; vmmPath: string; cpuSignature: string; baseImagePath: string; kernelPath: string; initramfsPath: string; attachmentPaths: string[] }
interface TemplateApi {
  hostCpuSignature(): Promise<string>
  forkDeskTemplate(snapshot: string, childDirectory: string, identity: { deskId: string; tap: string; mac: string; vsockCid: number; vsockSocket: string }, compatibility: Compatibility): Promise<unknown>
}
export interface TemplateForkOptions extends TemplateBuildOptions {
  childDirectory: string
  deskId: string
  slot: number
  attachments?: readonly DeskReadOnlyAttachment[]
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
  return {
    async holdFence(): Promise<void> { await fence.hold() },
    async prepare(plan: DeskLaunchPlan): Promise<void> {
      if (plan.hypervisor !== 'cloud-hypervisor') throw new Error('Template forks require Cloud Hypervisor')
      const api = desk as unknown as Partial<TemplateApi>
      if (typeof api.hostCpuSignature !== 'function' || typeof api.forkDeskTemplate !== 'function') throw new Error('Template forks require an AppKit desk release with template support')
      await buildTemplateSource(options)
      const version = (await exec(options.vmmPath, ['--version'], { timeout: 15_000 })).stdout.trim()
      const compatibility: Compatibility = { vmmVersion: version, vmmPath: options.vmmPath, cpuSignature: await api.hostCpuSignature(), baseImagePath: options.baseImage,
        kernelPath: options.kernel, initramfsPath: options.initramfs, attachmentPaths: (options.attachments ?? []).map(item => item.path) }
      await api.forkDeskTemplate(join(options.directory, 'source.snapshot'), options.childDirectory,
        { deskId: options.deskId, tap: plan.tap.device, mac: plan.tap.mac, vsockCid: plan.vsock.cid, vsockSocket: plan.vsock.socketPath }, compatibility)
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
