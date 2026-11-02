import { execFile } from 'node:child_process'
import { chmod, mkdtemp, mkdir, readFile, rm, writeFile } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join, resolve } from 'node:path'
import { promisify } from 'node:util'
import { describe, expect, it } from 'vitest'
import {
  resolveSystemImageAttachmentKind,
  selectSystemImage,
  systemImageAttachment,
  usesSystemImage,
  validateDepotRestoreOptions,
  type SystemImageBinding,
} from './system-image.js'

const execFileAsync = promisify(execFile)

describe('system-image', () => {
  it('binds only a new disk and retains the selected image across configuration changes', async () => {
    const root = await mkdtemp(join(tmpdir(), 'caboose-system-'))
    try {
      const first = join(root, 'one'), second = join(root, 'two'), binding = join(root, 'binding'), disk = join(root, 'disk'), snapshot = join(root, 'snapshot')
      for (const dir of [first, second]) {
        await mkdir(dir)
        for (const name of ['base.raw', 'vmlinux', 'initrd', 'system.erofs']) await writeFile(join(dir, name), `${dir}/${name}`)
      }
      expect(await usesSystemImage(binding, disk, snapshot, undefined)).toBe(false)
      expect(await usesSystemImage(binding, disk, snapshot, first)).toBe(true)
      const image = await selectSystemImage(binding, disk, snapshot, first)
      expect(image).not.toBeNull()
      await writeFile(disk, 'existing')
      // Once disk exists, base.raw is not re-verified on every wake, but system.erofs / vmlinux / initrd are.
      await writeFile(join(first, 'base.raw'), 'updated-base-ignored-after-disk-created')
      expect((await selectSystemImage(binding, disk, snapshot, second))?.directory).toBe(first)
      expect(await usesSystemImage(binding, disk, snapshot)).toBe(true)
      await writeFile(join(first, 'system.erofs'), 'changed')
      await expect(selectSystemImage(binding, disk, snapshot, second)).rejects.toThrow('retained system image changed')
      expect(JSON.parse(await readFile(binding, 'utf8')).hashes).toEqual(image?.hashes)
      await rm(binding)
      expect(await usesSystemImage(binding, disk, snapshot, second)).toBe(false)
      expect(await selectSystemImage(binding, disk, snapshot, second)).toBeNull()
      await rm(disk)
      await mkdir(snapshot)
      expect(await usesSystemImage(binding, disk, snapshot, second)).toBe(false)
      expect(await selectSystemImage(binding, disk, snapshot, second)).toBeNull()
    } finally {
      await rm(root, { recursive: true, force: true })
    }
  })

  it('rejects malformed saved system image bindings', async () => {
    const root = await mkdtemp(join(tmpdir(), 'caboose-system-invalid-'))
    try {
      const binding = join(root, 'binding'), disk = join(root, 'disk'), snapshot = join(root, 'snapshot')
      await writeFile(binding, JSON.stringify({ version: 1, directory: 'relative/path', hashes: {} }))
      await expect(selectSystemImage(binding, disk, snapshot)).rejects.toThrow('Invalid saved system image binding')
    } finally {
      await rm(root, { recursive: true, force: true })
    }
  })

  it('rejects a depot with copy-on-write restore because virtio-fs requires shared memory', () => {
    expect(() => validateDepotRestoreOptions('/depot', 'on')).toThrow(/requires shared memory/)
    expect(() => validateDepotRestoreOptions('/depot', 'off')).not.toThrow()
    expect(() => validateDepotRestoreOptions('/depot', undefined)).not.toThrow()
    expect(() => validateDepotRestoreOptions(undefined, 'on')).not.toThrow()
  })

  it('resolves attachment kind with pmem default for VMs, block default for templates, and env overrides', () => {
    expect(resolveSystemImageAttachmentKind()).toBe('pmem')
    expect(resolveSystemImageAttachmentKind(undefined, false)).toBe('pmem')
    expect(resolveSystemImageAttachmentKind('', false)).toBe('pmem')
    expect(resolveSystemImageAttachmentKind(undefined, true)).toBe('block')
    expect(resolveSystemImageAttachmentKind('', true)).toBe('block')
    expect(resolveSystemImageAttachmentKind('block', false)).toBe('block')
    expect(resolveSystemImageAttachmentKind('PMEM', true)).toBe('pmem')
    expect(resolveSystemImageAttachmentKind(' pmem ', false)).toBe('pmem')
    expect(() => resolveSystemImageAttachmentKind('virtiofs')).toThrow('System image attachment kind must be pmem or block')
  })

  it('builds systemImageAttachment descriptor with pmem default and explicit mode', () => {
    const sampleHash = 'a'.repeat(64)
    const binding: SystemImageBinding = {
      version: 1,
      directory: '/var/lib/caboose/split-v1',
      hashes: {
        'base.raw': sampleHash,
        vmlinux: sampleHash,
        initrd: sampleHash,
        'system.erofs': 'b'.repeat(64),
      },
    }
    expect(systemImageAttachment(binding)).toEqual({
      path: '/var/lib/caboose/split-v1/system.erofs',
      sha256: 'b'.repeat(64),
      kind: 'pmem',
    })
    expect(systemImageAttachment(binding, 'block')).toEqual({
      path: '/var/lib/caboose/split-v1/system.erofs',
      sha256: 'b'.repeat(64),
      kind: 'block',
    })
    expect(systemImageAttachment(binding, 'pmem')).toEqual({
      path: '/var/lib/caboose/split-v1/system.erofs',
      sha256: 'b'.repeat(64),
      kind: 'pmem',
    })
  })

  it('supports dax (default), fallback without -b, and lz4hc modes in make-system-image.sh with 2 MiB alignment', async () => {
    const root = await mkdtemp(join(tmpdir(), 'caboose-make-erofs-'))
    try {
      const binDir = join(root, 'bin')
      const guestRoot = join(root, 'guest')
      const logFile = join(root, 'calls.log')
      await mkdir(binDir, { recursive: true })
      await mkdir(join(guestRoot, 'usr', 'bin'), { recursive: true })
      await mkdir(join(guestRoot, 'opt'), { recursive: true })
      await writeFile(join(guestRoot, 'usr', 'bin', 'hello'), 'hello')

      await writeFile(join(binDir, 'mkfs.erofs'), `#!/usr/bin/env bash
set -euo pipefail
echo "mkfs.erofs $*" >> "${logFile}"
if [[ "\${REJECT_B_FLAG:-0}" == "1" && "$*" == *"-b 4096"* ]]; then
  exit 1
fi
for arg in "$@"; do
  if [[ $arg == *.part.* ]]; then
    printf 'erofs-image' > "$arg"
    exit 0
  fi
done
exit 1
`)
      await writeFile(join(binDir, 'fsck.erofs'), `#!/usr/bin/env bash
set -euo pipefail
echo "fsck.erofs $*" >> "${logFile}"
`)
      await writeFile(join(binDir, 'truncate'), `#!/usr/bin/env bash
set -euo pipefail
echo "truncate $*" >> "${logFile}"
`)
      await chmod(join(binDir, 'mkfs.erofs'), 0o755)
      await chmod(join(binDir, 'fsck.erofs'), 0o755)
      await chmod(join(binDir, 'truncate'), 0o755)

      const script = resolve(import.meta.dirname, '../../../guest/image/make-system-image.sh')
      const env = { ...process.env, PATH: `${binDir}:${process.env.PATH ?? ''}` }

      const daxOut = join(root, 'system-dax.erofs')
      await execFileAsync('bash', [script, guestRoot, daxOut], { env })

      const fallbackOut = join(root, 'system-fallback.erofs')
      await execFileAsync('bash', [script, '--dax', guestRoot, fallbackOut], {
        env: { ...env, REJECT_B_FLAG: '1' },
      })

      const lz4Out = join(root, 'system-lz4hc.erofs')
      await execFileAsync('bash', [script, guestRoot, lz4Out], {
        env: { ...env, CABOOSE_SYSTEM_IMAGE_FORMAT: 'lz4hc' },
      })

      await expect(
        execFileAsync('bash', [script, guestRoot, join(root, 'bad.erofs')], {
          env: { ...env, CABOOSE_SYSTEM_IMAGE_FORMAT: 'squashfs' },
        }),
      ).rejects.toThrow(/Unsupported CABOOSE_SYSTEM_IMAGE_FORMAT/)

      const log = await readFile(logFile, 'utf8')
      expect(log).toContain('mkfs.erofs -b 4096 -E noinline_data')
      expect(log).toContain('mkfs.erofs -E noinline_data')
      expect(log).toContain('mkfs.erofs -zlz4hc,12 -C65536')
      expect(log.match(/truncate -s %2097152/g)?.length).toBe(3)
    } finally {
      await rm(root, { recursive: true, force: true })
    }
  })

  it('includes PMEM/DAX modules and ro,dax fallback in initramfs caboose-system hook', async () => {
    const hookPath = resolve(import.meta.dirname, '../../../guest/image/initramfs/caboose-system')
    const { stdout } = await execFileAsync('sh', [hookPath, 'prereqs'])
    expect(stdout.trim()).toBe('')
    const content = await readFile(hookPath, 'utf8')
    expect(content).toContain('modprobe virtio_pmem 2>/dev/null || true')
    expect(content).toContain('modprobe nd_pmem 2>/dev/null || true')
    expect(content).toContain('modprobe dax_pmem 2>/dev/null || true')
    expect(content).toContain('/dev/pmem0')
    expect(content).toContain('mount -t erofs -o ro,dax "$device" "$rootmnt/.caboose-system"')
  })
})
