import { mkdtemp, readFile, rm, stat, writeFile } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { afterEach, describe, expect, it } from 'vitest'
import { ContainerSpecStore, parseContainerSpec, specArgs, specFromInspect } from './container-spec.js'

const roots: string[] = []
afterEach(async () => { for (const root of roots.splice(0)) await rm(root, { recursive: true, force: true }) })

const HALO = '/mnt/i/SteamLibrary/steamapps/common/Halo The Master Chief Collection'
/** What the host gives every computer on a WSL host (container-driver.ts providedArgs). */
const PROVIDED = ['-v', '/home/bsaun/caboose-gpu-home-c-e1e0cf1705:/home/caboose', '-v', 'caboose-depot:/var/lib/caboose/depot:ro',
  '--device', '/dev/dxg', '--device', '/dev/dri', '-v', '/usr/lib/wsl:/usr/lib/wsl:ro', '-e', 'LD_LIBRARY_PATH=/usr/lib/wsl/lib', '-e', 'CABOOSE_GPU=wsl', '--device', '/dev/userfaultfd']

describe('container settings', () => {
  it('accepts folders, devices, environment and security options', () => {
    expect(parseContainerSpec({ image: 'caboose-owner:steam-ready-5051b68', mounts: [{ source: `${HALO}/`, target: HALO, readOnly: true }],
      devices: [{ host: '/dev/dxg' }, { host: '/dev/dri/renderD128', container: '/dev/dri/renderD128' }], env: ['PROTON_LOG=1'], securityOpt: ['seccomp=unconfined', 'apparmor=unconfined'] }))
      .toEqual({ image: 'caboose-owner:steam-ready-5051b68', mounts: [{ source: HALO, target: HALO, readOnly: true }],
        devices: [{ host: '/dev/dxg' }, { host: '/dev/dri/renderD128' }], env: ['PROTON_LOG=1'], securityOpt: ['seccomp=unconfined', 'apparmor=unconfined'] })
  })
  it('refuses what would break or escape the computer', () => {
    for (const bad of [
      { extra: 1 }, { image: 'bad image' }, { mounts: [{ source: 'relative', target: '/x', readOnly: true }] },
      { mounts: [{ source: '/a', target: '/home/caboose', readOnly: false }] }, { mounts: [{ source: '/a', target: '/proc/x', readOnly: true }] },
      { mounts: [{ source: '/a/../etc', target: '/x', readOnly: true }] }, { mounts: [{ source: '/a', target: '/x' }] },
      { mounts: [{ source: '/a', target: '/x', readOnly: true }, { source: '/b', target: '/x', readOnly: true }] },
      { devices: [{ host: '/etc/shadow' }] }, { devices: [{ host: '/dev/a:/dev/b' }] },
      { env: ['1BAD=x'] }, { env: ['A=b\nc'] }, { securityOpt: ['privileged'] }, { securityOpt: ['seccomp={"defaultAction":"SCMP_ACT_ALLOW"}'] }, [],
    ]) expect(() => parseContainerSpec(bad), JSON.stringify(bad)).toThrow()
  })
  it('turns a spec into docker run arguments, quoting folder names and leaving out what the host provides', () => {
    const args = specArgs({ mounts: [{ source: HALO, target: HALO, readOnly: true }, { source: '/usr/lib/wsl', target: '/usr/lib/wsl', readOnly: true }, { source: '/srv/a,"b"', target: '/data', readOnly: false }],
      devices: [{ host: '/dev/dxg' }, { host: '/dev/dri/card0' }, { host: '/dev/kfd' }], env: ['A=1'], securityOpt: ['apparmor=unconfined'] }, PROVIDED)
    expect(args).toEqual([
      '--mount', `"type=bind","source=${HALO}","target=${HALO}","readonly"`,
      '--mount', '"type=bind","source=/srv/a,""b""","target=/data"',
      '--device', '/dev/kfd', '-e', 'A=1', '--security-opt', 'apparmor=unconfined',
    ])
  })
})

describe('reading a spec from an existing container', () => {
  // c-e1e0cf1705 on gpu-workstation, as docker inspect shows it.
  const inspect = {
    Config: { Image: 'caboose-computer:flathub-79f46a1', Env: ['LD_LIBRARY_PATH=/usr/lib/wsl/lib', 'CABOOSE_GPU=wsl', 'PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin', 'DEBIAN_FRONTEND=noninteractive', 'GAME_MODE=1'] },
    HostConfig: {
      Binds: ['/home/bsaun/caboose-gpu-home-c-e1e0cf1705:/home/caboose', 'caboose-depot:/var/lib/caboose/depot:ro', '/usr/lib/wsl:/usr/lib/wsl:ro'],
      Mounts: [{ Type: 'bind', Source: HALO, Target: HALO, ReadOnly: true }, { Type: 'bind', Source: '/home/bsaun/caboose-halo-evaluation/native', Target: '/opt/caboose-games/halo-mcc', ReadOnly: true },
        { Type: 'bind', Source: '/home/bsaun/gpu-remoting/ge', Target: '/opt/caboose-games/GE-Proton11-11', ReadOnly: true }],
      Devices: [{ PathOnHost: '/dev/dxg', PathInContainer: '/dev/dxg' }, { PathOnHost: '/dev/userfaultfd', PathInContainer: '/dev/userfaultfd' }, { PathOnHost: '/dev/dri/card0', PathInContainer: '/dev/dri/card0' }],
      SecurityOpt: ['seccomp={"defaultAction":"SCMP_ACT_ERRNO"}', 'writable-cgroups=true'],
    },
  }
  const imageEnv = ['PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin', 'DEBIAN_FRONTEND=noninteractive']
  it('keeps its image, game folders and own environment, and leaves the host’s defaults out', () => {
    expect(specFromInspect(inspect, PROVIDED, imageEnv)).toEqual({
      image: 'caboose-computer:flathub-79f46a1',
      mounts: [{ source: HALO, target: HALO, readOnly: true }, { source: '/home/bsaun/caboose-halo-evaluation/native', target: '/opt/caboose-games/halo-mcc', readOnly: true },
        { source: '/home/bsaun/gpu-remoting/ge', target: '/opt/caboose-games/GE-Proton11-11', readOnly: true }],
      env: ['GAME_MODE=1'],
    })
  })
  it('keeps devices the host would not give it again', () => {
    const withoutVgem = ['-v', '/home/x:/home/caboose', '--device', '/dev/dxg', '-v', '/usr/lib/wsl:/usr/lib/wsl:ro']
    expect(specFromInspect(inspect, withoutVgem, imageEnv).devices)
      .toEqual([{ host: '/dev/userfaultfd' }, { host: '/dev/dri/card0' }])
  })
})

describe('the container settings file', () => {
  it('is empty until set, then kept privately across restarts', async () => {
    const root = await mkdtemp(join(tmpdir(), 'caboose-spec-')); roots.push(root)
    const path = join(root, 'container.json')
    const store = await ContainerSpecStore.open(path)
    expect(store.get()).toEqual({})
    await store.set({ image: 'caboose-owner:steam-ready-5051b68', mounts: [{ source: HALO, target: HALO, readOnly: true }] })
    expect((await stat(path)).mode & 0o777).toBe(0o600)
    expect((await ContainerSpecStore.open(path)).get().image).toBe('caboose-owner:steam-ready-5051b68')
    await expect(store.set({ mounts: [{ source: '/a', target: '/home/caboose', readOnly: true }] })).rejects.toThrow()
    expect(JSON.parse(await readFile(path, 'utf8')).image).toBe('caboose-owner:steam-ready-5051b68')
  })
  it('refuses to start from a damaged file rather than lose a computer’s folders', async () => {
    const root = await mkdtemp(join(tmpdir(), 'caboose-spec-')); roots.push(root)
    await writeFile(join(root, 'container.json'), '{"mounts": "nope"}')
    await expect(ContainerSpecStore.open(join(root, 'container.json'))).rejects.toThrow()
  })
})
