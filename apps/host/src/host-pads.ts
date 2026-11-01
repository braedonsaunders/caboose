import { spawn as spawnProcess, type ChildProcessWithoutNullStreams } from 'node:child_process'
import { createInterface } from 'node:readline'

/**
 * Gamepads for a container computer (docs/devices.md, "Gamepads in container computers").
 * A container has no uinput, and must not: the host makes each of the phone's controllers
 * with its own uinput, in a sidecar container that holds /dev/uinput and nothing else
 * (`caboose-display --host-pads`), and puts only the pad's evdev node into the computer.
 * The computer is created allowed to open input devices (major 13) but unable to make
 * device nodes, so the nodes the host makes are the only ones it can open.
 *
 * The owner display's device hub asks for pads over a link the host opens into the
 * computer (`caboose-display --pad-link`); the host passes the hub's lines to the sidecar
 * and the sidecar's back, making each pad's node in the computer before the hub hears of it
 * and removing it before the pad goes, so a node never outlives its pad.
 */

/** Input devices (evdev nodes) a computer may open: only those the host makes in it. */
export const INPUT_DEVICE_RULE = 'c 13:* rwm'
const DISPLAY_BINARY = '/usr/local/bin/caboose-display'
/** The longest line passed on; the hub and the sidecar drop longer ones too. */
export const LINE_MAX = 1024

/** What a container computer is created with so that the host can give it gamepads. */
export function inputDeviceArgs(): string[] {
  return ['--device-cgroup-rule', INPUT_DEVICE_RULE, '--cap-drop', 'MKNOD']
}

/** Whether a container's `HostConfig.DeviceCgroupRules` (JSON) let it open the host's pads. */
export function allowsPads(rulesJson: string): boolean {
  try {
    const rules = JSON.parse(rulesJson) as unknown
    return Array.isArray(rules) && rules.includes(INPUT_DEVICE_RULE)
  } catch {
    return false
  }
}

export function sidecarName(computer: string): string {
  return `${computer}-pads`
}

/** The sidecar: the computer's own image's caboose-display, with uinput and no capabilities, network or writable files. */
export function sidecarArgs(computer: string, image: string): string[] {
  return ['run', '--rm', '-i', '--name', sidecarName(computer), '--device', '/dev/uinput', '--cap-drop', 'ALL',
    '--security-opt', 'no-new-privileges', '--network', 'none', '--read-only', '--user', '0', '--log-driver', 'none',
    '--entrypoint', DISPLAY_BINARY, image, '--host-pads']
}

/** The link into the computer, as its owner, in the owner display's runtime directory. */
export function linkArgs(computer: string, ownerEnv: readonly string[]): string[] {
  const runtime = ownerEnv.filter(pair => pair.startsWith('XDG_RUNTIME_DIR=')).pop()
  return ['exec', '-i', '-u', 'caboose', computer, '/usr/bin/env', ...(runtime ? [runtime] : []), DISPLAY_BINARY, '--pad-link']
}

/** Makes `$1` the character device `$2:$3`, which only its owner, `caboose`, opens. */
export const MAKE_NODE = 'set -e; mkdir -p /dev/input; rm -f "$1"; mknod -m 0600 "$1" c "$2" "$3"; chown caboose:caboose "$1"'
/** The computer's input nodes: all are the host's pads. */
export const CLEAR_NODES = 'mkdir -p /dev/input; rm -f /dev/input/event*'

/** `docker exec` that makes a node: privileged, the only way a node is made in the computer. */
export function makeNodeArgs(computer: string, node: string, major: number, minor: number): string[] {
  return ['exec', '--privileged', '-u', 'root', computer, '/bin/sh', '-c', MAKE_NODE, 'sh', node, String(major), String(minor)]
}

export function clearNodesArgs(computer: string): string[] {
  return ['exec', '-u', 'root', computer, '/bin/sh', '-c', CLEAR_NODES]
}

export function removeNodeArgs(computer: string, node: string): string[] {
  return ['exec', '-u', 'root', computer, '/bin/rm', '-f', node]
}

export interface AddedPad { id: number; node: string; major: number; minor: number }

const ID = (value: unknown): number | null => Number.isSafeInteger(value) && (value as number) > 0 && (value as number) < 2 ** 32 ? value as number : null

function object(line: string): Record<string, unknown> | null {
  if (line.length > LINE_MAX) return null
  try {
    const value = JSON.parse(line) as unknown
    return value && typeof value === 'object' && !Array.isArray(value) ? value as Record<string, unknown> : null
  } catch {
    return null
  }
}

/** A pad the sidecar made: `{"added":ID,"node":"/dev/input/eventN","dev":"13:M"}`. Only evdev nodes of input devices. */
export function parseAdded(line: string): AddedPad | null {
  const value = object(line)
  const id = ID(value?.added)
  if (!value || id === null || typeof value.node !== 'string' || typeof value.dev !== 'string') return null
  if (!/^\/dev\/input\/event\d{1,5}$/.test(value.node)) return null
  const dev = /^(13):(\d{1,7})$/.exec(value.dev)
  if (!dev) return null
  return { id, node: value.node, major: Number(dev[1]), minor: Number(dev[2]) }
}

/** The pad a hub's `{"remove":ID}` takes down. */
export function parseRemove(line: string): number | null {
  return ID(object(line)?.remove)
}

export type Docker = (args: string[], timeoutMs?: number) => Promise<string>

export interface HostPadsOptions {
  /** The computer's container. */
  computer: string
  docker: Docker
  /** The image the sidecar runs: the computer's own. */
  image: () => Promise<string>
  /** The owner display's launch environment. */
  ownerEnv: () => readonly string[]
  spawn?: (args: string[]) => ChildProcessWithoutNullStreams
  retryMs?: number
  log?: (message: string) => void
}

/** One computer's host pads: the link, the sidecar and the nodes between them. */
export class HostPads {
  private running = false
  private link?: ChildProcessWithoutNullStreams
  private sidecar?: ChildProcessWithoutNullStreams
  private readonly nodes = new Map<number, string>()
  private retry?: NodeJS.Timeout
  private lastError = ''
  private session = 0

  constructor(private readonly options: HostPadsOptions) {}

  /** Links the computer's owner display to a sidecar, and again whenever the link ends, until stopped. */
  start(): void {
    if (this.running) return
    this.running = true
    void this.connect()
  }

  /** Takes every pad's node out of the computer, then the pads down. */
  async stop(): Promise<void> {
    this.running = false
    this.session++
    clearTimeout(this.retry)
    await this.end()
  }

  private async connect(): Promise<void> {
    const { docker, computer } = this.options
    const session = ++this.session
    try {
      await docker(clearNodesArgs(computer), 15_000)
      await docker(['rm', '-f', sidecarName(computer)], 30_000).catch(() => '')
      const image = await this.options.image()
      if (!this.running || session !== this.session) return
      const spawn = this.options.spawn ?? (args => spawnProcess('docker', args, { stdio: ['pipe', 'pipe', 'pipe'] }))
      const sidecar = this.sidecar = spawn(sidecarArgs(computer, image))
      const link = this.link = spawn(linkArgs(computer, this.options.ownerEnv()))
      let stderr = ''
      for (const child of [sidecar, link]) {
        child.stderr.on('data', (chunk: Buffer) => { stderr = (stderr + chunk.toString()).slice(-400) })
        child.stdin.on('error', () => {})
        child.on('error', error => this.ended(session, error.message))
        child.on('close', () => this.ended(session, stderr.trim() || (child === link ? 'the link ended' : 'the pad service ended')))
      }
      createInterface({ input: link.stdout, crlfDelay: Infinity }).on('line', line => void this.fromHub(line, sidecar))
      createInterface({ input: sidecar.stdout, crlfDelay: Infinity }).on('line', line => void this.fromSidecar(line, link, sidecar))
    } catch (error) {
      this.ended(session, error instanceof Error ? error.message : String(error))
    }
  }

  private async fromHub(line: string, sidecar: ChildProcessWithoutNullStreams): Promise<void> {
    if (line.length > LINE_MAX) return
    const removed = parseRemove(line)
    const node = removed === null ? undefined : this.nodes.get(removed)
    if (removed !== null && node) {
      // The node goes before the pad, so its device numbers are never reused under it.
      this.nodes.delete(removed)
      await this.options.docker(removeNodeArgs(this.options.computer, node), 15_000).catch(() => this.options.docker(clearNodesArgs(this.options.computer), 15_000)).catch(() => '')
    }
    sidecar.stdin.write(`${line}\n`)
  }

  private async fromSidecar(line: string, link: ChildProcessWithoutNullStreams, sidecar: ChildProcessWithoutNullStreams): Promise<void> {
    const added = parseAdded(line)
    if (added) {
      try {
        await this.options.docker(makeNodeArgs(this.options.computer, added.node, added.major, added.minor), 15_000)
        this.nodes.set(added.id, added.node)
      } catch (error) {
        const reason = `The host could not give this computer ${added.node}: ${error instanceof Error ? error.message : String(error)}`.slice(0, 200)
        sidecar.stdin.write(`${JSON.stringify({ remove: added.id })}\n`)
        link.stdin.write(`${JSON.stringify({ failed: added.id, error: reason })}\n`)
        return
      }
    }
    link.stdin.write(`${line}\n`)
  }

  private ended(session: number, reason: string): void {
    if (session !== this.session) return
    this.session++
    if (reason !== this.lastError) {
      this.lastError = reason
      ;(this.options.log ?? console.error)(`Gamepads for ${this.options.computer}: ${reason}`)
    }
    void this.end().then(() => {
      if (this.running) this.retry = setTimeout(() => void this.connect(), this.options.retryMs ?? 5000)
    })
  }

  private async end(): Promise<void> {
    const { link, sidecar } = this
    this.link = this.sidecar = undefined
    link?.stdin.end()
    link?.kill()
    if (this.nodes.size || sidecar) {
      this.nodes.clear()
      await this.options.docker(clearNodesArgs(this.options.computer), 15_000).catch(() => '')
    }
    sidecar?.stdin.end()
    sidecar?.kill()
  }
}
