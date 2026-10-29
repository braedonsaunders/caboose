import { mkdir, readFile, readlink, stat, writeFile } from 'node:fs/promises'
import { execFile, spawn } from 'node:child_process'
import { promisify } from 'node:util'
import { pathToFileURL } from 'node:url'
import { join } from 'node:path'

const root = process.env.TEMPLATE_CHECK_STAGE
if (!root || !root.startsWith('/')) throw new Error('TEMPLATE_CHECK_STAGE must name an absolute disposable stage')
if (await readlink('/proc/self/ns/net') === await readlink('/proc/1/ns/net')) throw new Error('A private network namespace is required')
const { buildTemplateSource } = await import(pathToFileURL(join(root, 'apps/host/src/template-builder.ts')).href)
const { readBundle } = await import(pathToFileURL(join(root, 'apps/host/src/components.ts')).href)
const { hostCpuSignature, forkDeskTemplate, verifyDeskTemplateFork } = await import(pathToFileURL(join(root, 'node_modules/@braedonsaunders/appkit-desk/index.js')).href)
const snapshot = join(root, 'templates', 'a'.repeat(64), 'source.snapshot')
const directory = join(root, 'templates', 'a'.repeat(64))
const options = { directory, baseImage: join(root, 'base.raw'), kernel: join(root, 'vmlinux'), initramfs: join(root, 'initrd'), vmmPath: '/usr/local/bin/cloud-hypervisor', memoryMb: 1024, vcpus: 2 }
if (process.env.TEMPLATE_CHECK_RECOVERY_ONLY !== '1') {
await buildTemplateSource(options)
console.log('PASS production source builder and complete component verification')
const compatibility = { vmmVersion: 'cloud-hypervisor v54.0', vmmPath: options.vmmPath, cpuSignature: await hostCpuSignature(), componentVersion: (await readBundle()).version, baseImagePath: options.baseImage, kernelPath: options.kernel, initramfsPath: options.initramfs, attachmentPaths: [] }
const identity = { deskId: 'check', tap: 'dsk932103', mac: '06:00:00:00:00:03', vsockCid: 433103, vsockSocket: join(root, 'runtime', 'desk-check.vsock') }
const childDir = join(root, 'overlays', 'child')
const fork = await forkDeskTemplate(snapshot, childDir, identity, compatibility)
await verifyDeskTemplateFork(childDir, identity, compatibility)
const a = await stat(join(snapshot, 'memory-ranges')), b = await stat(join(fork.snapshotPath, 'memory-ranges'))
if (a.dev !== b.dev || a.ino !== b.ino) throw new Error('memory inode differs')
console.log('PASS registered full-hash fork and shared inode')
const config = join(fork.snapshotPath, 'config.json')
await writeFile(config, '{}')
let rejected = false
try { await verifyDeskTemplateFork(childDir, identity, compatibility) } catch { rejected = true }
if (!rejected) throw new Error('tampered child was accepted')
console.log('PASS prepared-fork recovery refuses changed configuration')
console.log(`component version ${(await readBundle()).version}`)
console.log(`source ready ${(await readFile(join(directory, '.ready'), 'utf8')).trim()}`)
}

const exec = promisify(execFile)
const recovery = join(root, 'apps/host/scripts/recover-template-source.sh')
const failedId = 'b'.repeat(64), failedDir = join(root, 'templates', failedId)
await mkdir(failedDir)
await writeFile(join(failedDir, '.build.json'), JSON.stringify({ version: 1, tap: 'dsk123456789', runtime: join(root, 'runtime', 'tpl-interrupted') }))
let refused = false
try { await exec('bash', [recovery, root, failedId]) } catch (error) { refused = String((error as { stderr?: string }).stderr).includes('ownership was not committed') }
if (!refused) throw new Error('Ambiguous TAP ownership was not rejected')
console.log('PASS parent-failure recovery refuses uncommitted TAP ownership')
const lock = spawn('python3', ['-c', 'import fcntl,sys; f=open(sys.argv[1],"w"); fcntl.flock(f,fcntl.LOCK_EX); print("locked",flush=True); sys.stdin.read()', join(root, '.host.lock')], { stdio: ['pipe', 'pipe', 'pipe'] })
try {
  await new Promise<void>((resolve, reject) => { lock.stdout.once('data', () => resolve()); lock.once('error', reject) })
  refused = false
  try { await exec('bash', [recovery, root, failedId]) } catch (error) { refused = String((error as { stderr?: string }).stderr).includes('locked by a host or VM') }
  if (!refused) throw new Error('Recovery bypassed live host lock')
  console.log('PASS parent-failure recovery refuses live host lock')
} finally {
  lock.stdin.end()
  await new Promise<void>(resolve => lock.once('exit', () => resolve()))
}
