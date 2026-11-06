import { readFile } from 'node:fs/promises'
import { writePrivateJson } from './settings.js'

/**
 * What one container computer is created with beyond the host's defaults
 * (docs/architecture.md § Computers): its image, host folders, devices, environment and
 * security options. The host keeps it in the computer's own state (`container.json`), so a
 * container that has to be created again (after it was removed, or for an image change) comes
 * back with everything it had. Only the operator sets it: it reaches into the host.
 */
export interface ContainerSpec {
  /** Overrides CABOOSE_CONTAINER_IMAGE for this computer. */
  image?: string
  mounts?: HostFolder[]
  /** Host device nodes; `container` defaults to the same path. */
  devices?: Array<{ host: string; container?: string }>
  /** `KEY=value`. */
  env?: string[]
  /** Docker `--security-opt` values, such as `seccomp=unconfined` or `apparmor=unconfined`. */
  securityOpt?: string[]
}

export class ContainerSpecError extends Error {}

const IMAGE = /^[a-z0-9][a-z0-9._/:@-]{0,254}$/i
const ENV = /^[A-Za-z_][A-Za-z0-9_]{0,127}=[^\n\r\0]{0,4096}$/
const SECURITY = /^(?:seccomp=(?:unconfined|\/[^\n\r\0]{1,4095})|apparmor=[A-Za-z0-9_.-]{1,128}|label=[A-Za-z0-9_.:=-]{1,256}|no-new-privileges(?::(?:true|false))?|systempaths=unconfined|writable-cgroups=(?:true|false))$/
/** Paths a computer's own setup owns: a folder from the host never replaces them. */
const RESERVED = ['/', '/home/caboose', '/var/lib/caboose/depot', '/proc', '/sys', '/dev', '/run', '/etc', '/usr', '/bin', '/sbin', '/lib', '/var', '/tmp', '/boot']

function absolute(value: unknown, label: string): string {
  if (typeof value !== 'string' || !value.startsWith('/') || value.length > 4096 || /[\0\n\r"]/.test(value) || value.split('/').includes('..')) {
    throw new ContainerSpecError(`${label} must be an absolute path without "..", quotes or newlines`)
  }
  return value.length > 1 ? value.replace(/\/+$/, '') : value
}

/** A folder of the host a computer gets at `target`, read-write unless `readOnly`. */
export interface HostFolder { source: string; target: string; readOnly: boolean }

/**
 * Host folders checked one by one: absolute paths without "..", none over a path the computer's
 * own setup owns, no two at one target. Shared by container mounts and microVM folders.
 */
export function parseFolders(items: unknown[], Failure: new (message: string) => Error): HostFolder[] {
  const targets = new Set<string>()
  return items.map(item => {
    const mount = (item ?? {}) as Record<string, unknown>
    if (typeof item !== 'object' || Object.keys(mount).some(key => !['source', 'target', 'readOnly'].includes(key))) throw new Failure('A folder is { source, target, readOnly }')
    let source: string, target: string
    try { source = absolute(mount.source, 'A folder source'); target = absolute(mount.target, 'A folder target') }
    catch (error) { throw new Failure((error as Error).message) }
    if (typeof mount.readOnly !== 'boolean') throw new Failure('A folder needs readOnly true or false')
    if (RESERVED.includes(target) || target.startsWith('/proc/') || target.startsWith('/sys/') || target.startsWith('/dev/') || target.startsWith('/run/')) throw new Failure(`A host folder cannot replace ${target}`)
    if (targets.has(target)) throw new Failure(`Two folders share ${target}`)
    targets.add(target)
    return { source, target, readOnly: mount.readOnly }
  })
}

/** Checks a spec field by field; unknown fields are errors. */
export function parseContainerSpec(input: unknown): ContainerSpec {
  if (!input || typeof input !== 'object' || Array.isArray(input)) throw new ContainerSpecError('The container settings must be an object')
  const value = input as Record<string, unknown>
  for (const key of Object.keys(value)) if (!['image', 'mounts', 'devices', 'env', 'securityOpt'].includes(key)) throw new ContainerSpecError(`Unknown container setting: ${key}`)
  const spec: ContainerSpec = {}
  if (value.image !== undefined) {
    if (typeof value.image !== 'string' || !IMAGE.test(value.image)) throw new ContainerSpecError('image must be a Docker image reference')
    spec.image = value.image
  }
  const list = (key: string, max: number): unknown[] | undefined => {
    if (value[key] === undefined) return undefined
    if (!Array.isArray(value[key]) || (value[key] as unknown[]).length > max) throw new ContainerSpecError(`${key} must be a list of at most ${max}`)
    return value[key] as unknown[]
  }
  const mounts = list('mounts', 64)
  if (mounts) spec.mounts = parseFolders(mounts, ContainerSpecError)
  const devices = list('devices', 32)
  if (devices) {
    spec.devices = devices.map(item => {
      const device = (item ?? {}) as Record<string, unknown>
      if (typeof item !== 'object' || Object.keys(device).some(key => !['host', 'container'].includes(key))) throw new ContainerSpecError('A device is { host, container? }')
      const host = absolute(device.host, 'A device'), container = device.container === undefined ? undefined : absolute(device.container, 'A device')
      if (!host.startsWith('/dev/') || (container !== undefined && !container.startsWith('/dev/')) || /:/.test(host + (container ?? ''))) throw new ContainerSpecError('Devices are paths under /dev without colons')
      return container && container !== host ? { host, container } : { host }
    })
  }
  const env = list('env', 128)
  if (env) {
    if (!env.every(item => typeof item === 'string' && ENV.test(item))) throw new ContainerSpecError('env entries are KEY=value')
    spec.env = env as string[]
  }
  const security = list('securityOpt', 16)
  if (security) {
    if (!security.every(item => typeof item === 'string' && SECURITY.test(item))) throw new ContainerSpecError('securityOpt entries are seccomp=unconfined or a profile path, apparmor=, label=, no-new-privileges, systempaths=unconfined or writable-cgroups=')
    spec.securityOpt = security as string[]
  }
  return spec
}

/** A CSV field for `--mount`, which Docker reads with encoding/csv: quoted, quotes doubled. */
const field = (value: string) => `"${value.replace(/"/g, '""')}"`

/**
 * `docker run` arguments for a spec, leaving out what the host already gives every computer:
 * `provided` are the default arguments, whose mount targets and devices win.
 */
export function specArgs(spec: ContainerSpec, provided: readonly string[]): string[] {
  const targets = new Set<string>(), devices = new Set<string>()
  for (let index = 0; index < provided.length - 1; index++) {
    const [flag, value] = [provided[index], provided[index + 1]!]
    if (flag === '-v') targets.add(value.split(':')[1] ?? '')
    if (flag === '--device') devices.add(value.split(':')[0]!)
  }
  const covered = (host: string) => devices.has(host) || [...devices].some(path => host.startsWith(`${path}/`))
  return [
    ...(spec.mounts ?? []).filter(mount => !targets.has(mount.target)).flatMap(mount => ['--mount', [field('type=bind'), field(`source=${mount.source}`), field(`target=${mount.target}`), ...(mount.readOnly ? [field('readonly')] : [])].join(',')]),
    ...(spec.devices ?? []).filter(device => !covered(device.host)).flatMap(device => ['--device', device.container ? `${device.host}:${device.container}` : device.host]),
    ...(spec.env ?? []).flatMap(entry => ['-e', entry]),
    ...(spec.securityOpt ?? []).flatMap(option => ['--security-opt', option]),
  ]
}

/** The parts of `docker inspect` a spec is read from. */
export interface ContainerInspect {
  Config?: { Image?: string; Env?: string[] }
  HostConfig?: {
    Binds?: string[] | null
    Mounts?: Array<{ Type?: string; Source?: string; Target?: string; ReadOnly?: boolean }> | null
    Devices?: Array<{ PathOnHost?: string; PathInContainer?: string }> | null
    SecurityOpt?: string[] | null
  }
}

/**
 * The spec an existing container was created with, so that recreating it loses nothing:
 * its image, host folders and devices beyond the host's defaults (`provided`), environment
 * beyond its image's (`imageEnv`) and the host's, and its non-default security options.
 * Volumes (the home, the depot) and the default seccomp profile are the host's own.
 */
export function specFromInspect(inspect: ContainerInspect, provided: readonly string[], imageEnv: readonly string[]): ContainerSpec {
  const defaults = new Set(imageEnv)
  for (let index = 0; index < provided.length - 1; index++) if (provided[index] === '-e') defaults.add(provided[index + 1]!)
  const mounts: NonNullable<ContainerSpec['mounts']> = []
  for (const bind of inspect.HostConfig?.Binds ?? []) {
    const [source, target, options = ''] = bind.split(':')
    if (source?.startsWith('/') && target && target !== '/home/caboose') mounts.push({ source, target, readOnly: options.split(',').includes('ro') })
  }
  for (const mount of inspect.HostConfig?.Mounts ?? []) {
    if (mount.Type === 'bind' && mount.Source && mount.Target && mount.Target !== '/home/caboose') mounts.push({ source: mount.Source, target: mount.Target, readOnly: !!mount.ReadOnly })
  }
  const spec: ContainerSpec = {
    ...(inspect.Config?.Image ? { image: inspect.Config.Image } : {}),
    mounts,
    devices: (inspect.HostConfig?.Devices ?? []).flatMap(device => device.PathOnHost ? [device.PathInContainer && device.PathInContainer !== device.PathOnHost ? { host: device.PathOnHost, container: device.PathInContainer } : { host: device.PathOnHost }] : []),
    env: (inspect.Config?.Env ?? []).filter(entry => !defaults.has(entry) && ENV.test(entry)),
    securityOpt: (inspect.HostConfig?.SecurityOpt ?? []).filter(option => SECURITY.test(option) && option !== 'writable-cgroups=true'),
  }
  // What the host provides anyway is left out, as specArgs would.
  const kept = specArgs(spec, provided)
  spec.mounts = spec.mounts!.filter(mount => kept.some(arg => arg.includes(field(`target=${mount.target}`))))
  spec.devices = spec.devices!.filter(device => kept.includes(device.container ? `${device.host}:${device.container}` : device.host))
  return parseContainerSpec(Object.fromEntries(Object.entries(spec).filter(([, item]) => !Array.isArray(item) || item.length)))
}

/** `container.json` in a computer's state directory, written atomically with mode 0600. */
export class ContainerSpecStore {
  private constructor(private readonly path: string, private value: ContainerSpec) {}

  static async open(path: string): Promise<ContainerSpecStore> {
    let raw: string | undefined
    try { raw = await readFile(path, 'utf8') } catch (error) { if ((error as NodeJS.ErrnoException).code !== 'ENOENT') throw error }
    // A damaged file stops the host rather than recreating a computer without its folders.
    return new ContainerSpecStore(path, raw === undefined ? {} : parseContainerSpec(JSON.parse(raw)))
  }

  get(): ContainerSpec { return structuredClone(this.value) }

  async set(input: unknown): Promise<ContainerSpec> {
    const next = parseContainerSpec(input)
    await writePrivateJson(this.path, next)
    this.value = next
    return this.get()
  }
}
