/** Run only in a private Linux network namespace with a disposable reflinked base disk. */
import { chmod, copyFile, mkdir, readFile, readdir, readlink, stat, writeFile } from 'node:fs/promises'
import { pathToFileURL } from 'node:url'
import { constants } from 'node:fs'
import { join } from 'node:path'

const required = (key: string): string => { const value = process.env[key]; if (!value) throw new Error(`${key} required`); return value }
const stage = required('TEMPLATE_CHECK_STAGE')
const { createDeskHost, createDeskNetwork, createCloudHypervisorBackend, hostCpuSignature, registerDeskTemplate, forkDeskTemplate, verifyDeskTemplateFork, planTemplateConfig, pinTemplateMemory } = await import(pathToFileURL(required('APPKIT_DESK_ENTRY')).href)
if (await readlink('/proc/self/ns/net') === await readlink('/proc/1/ns/net')) throw new Error('A private network namespace is required')
const [golden, disposable] = await Promise.all([stat(required('TEMPLATE_CHECK_GOLDEN')), stat(join(stage, 'base.raw'))])
if (golden.dev !== disposable.dev || golden.ino === disposable.ino) throw new Error('Test disk must be a distinct copy on the golden disk filesystem')
const disk = join(stage, 'base.raw'), snapshot = join(stage, 'source.snapshot'), runtime = join(stage, 'runtime')
const kernel = join(stage, 'vmlinux'), initrd = join(stage, 'initrd')
await mkdir(runtime, { recursive: true })
const host = createDeskHost({ imageRoot: stage, runtimeDir: runtime, vmmPath: '/usr/local/bin/cloud-hypervisor', cidBase: 433100,
  backend: createCloudHypervisorBackend({ connectTimeoutMs: 120_000 }), parkWithMemory: true, memoryRestoreMode: 'copyonwrite', strictMemoryRestore: true,
  kernelCmdline: 'root=/dev/vda3 rw caboose.template=1 systemd.unit=caboose-template.target', trimOnSuspend: false, capacity: 3,
  ports: { onEvent: () => {}, audit: () => {} } })
const bootstrap = createDeskHost({ imageRoot: stage, runtimeDir: join(stage, 'runtime-bootstrap'), vmmPath: '/usr/local/bin/cloud-hypervisor', cidBase: 433099,
  backend: createCloudHypervisorBackend({ connectTimeoutMs: 120_000 }), parkWithMemory: false,
  kernelCmdline: 'root=/dev/vda3 rw', trimOnSuspend: false, ports: { onEvent: () => {}, audit: () => {} } })
const networks = [createDeskNetwork({ gateway: '172.30.92.1', dns: '1.1.1.1', egress: { mode: 'open' } }), createDeskNetwork({ gateway: '172.30.93.1', dns: '1.1.1.1', egress: { mode: 'open' } }), createDeskNetwork({ gateway: '172.30.94.1', dns: '1.1.1.1', egress: { mode: 'open' } })]
const ids = ['source', 'child', 'child2']
try {
  await networks[0]!.ensure({ tap: 'dsk932100', guest: '172.30.92.2' })
  await mkdir(join(stage, 'runtime-bootstrap'), { recursive: true })
  const installer = await bootstrap.start({ deskId: 'bootstrap', baseImage: disk, overlayPath: disk, memoryMb: 1024, vcpus: 2, network: { tapDevice: 'dsk932100', guestAddress: '172.30.92.2' } })
  const helper = await readFile(join(stage, 'guest/template/caboose-template.py'))
  const unit = await readFile(join(stage, 'guest/template/caboose-template.target'))
  const install = `import base64,pathlib; pathlib.Path('/usr/local/libexec/caboose-template').write_bytes(base64.b64decode('${helper.toString('base64')}')); pathlib.Path('/etc/systemd/system/caboose-template.target').write_bytes(base64.b64decode('${unit.toString('base64')}'))`
  const debPath = process.env.TEMPLATE_CHECK_WEBSOCKETS_DEB
  if (debPath) {
    const bytes = await readFile(debPath)
    const encoded = bytes.toString('base64')
    const guestDeb = '/tmp/caboose-template-websockets.deb'
    const reset = await installer.exec({ command: '/bin/sh', args: ['-c', ': > "$1"', 'sh', guestDeb] })
    if (reset.exitCode !== 0) throw new Error('Unable to stage fixture package')
    for (let offset = 0; offset < encoded.length; offset += 48 * 1024) {
      const write = await installer.exec({ command: '/bin/sh', args: ['-c', 'printf %s "$2" | base64 -d >> "$1"', 'sh', guestDeb, encoded.slice(offset, offset + 48 * 1024)] })
      if (write.exitCode !== 0) throw new Error(`Unable to stage fixture package: ${write.stderr}`)
    }
    const installPackage = await installer.exec({ command: '/usr/bin/dpkg', args: ['-i', guestDeb], timeoutMs: 120_000 })
    if (installPackage.exitCode !== 0) throw new Error(`Fixture package installation failed: ${installPackage.stderr}`)
    const remove = await installer.exec({ command: '/bin/rm', args: ['-f', guestDeb] })
    if (remove.exitCode !== 0) throw new Error('Unable to remove staged fixture package')
  }
  const dependencies = await installer.exec({ command: '/usr/bin/python3', args: ['-c', 'from websockets.asyncio.server import serve; print("terminal dependency ready")'] })
  console.log(dependencies.exitCode === 0 ? 'PASS disposable golden terminal Python dependency' : `CHECK terminal dependency unavailable: ${dependencies.stderr}`)
  const installed = await installer.exec({ command: '/usr/bin/python3', args: ['-c', install] })
  if (installed.exitCode !== 0) throw new Error(`install failed: ${installed.stderr}`)
  // Older golden images may predate these components. Install the exact bundled
  // service files into this disposable test disk before the isolated cold boot.
  const assets = [
    ['guest/files/caboose-files.py', '/opt/caboose/files/caboose-files.py'],
    ['guest/files/caboose-files.service', '/etc/systemd/system/caboose-files.service'],
    ['guest/terminal/caboose-terminal.py', '/opt/caboose/terminal/caboose-terminal.py'],
    ['guest/terminal/caboose-terminal.service', '/etc/systemd/system/caboose-terminal.service'],
    ['guest/components/caboose-vsock-services.py', '/opt/caboose/vsock/caboose-vsock-services.py'],
    ['guest/components/caboose-vsock-services.service', '/etc/systemd/system/caboose-vsock-services.service'],
  ]
  for (const [from, to] of assets) {
    const bytes = await readFile(join(stage, from!))
    const script = `import base64,pathlib; p=pathlib.Path(${JSON.stringify(to)}); p.parent.mkdir(parents=True,exist_ok=True); p.write_bytes(base64.b64decode('${bytes.toString('base64')}'))`
    const written = await installer.exec({ command: '/usr/bin/python3', args: ['-c', script] })
    if (written.exitCode !== 0) throw new Error(`component install failed: ${written.stderr}`)
  }
  const reload = await installer.exec({ command: '/bin/systemctl', args: ['daemon-reload'] })
  if (reload.exitCode !== 0) throw new Error(`reload failed: ${reload.stderr}`)
  const enabled = await installer.exec({ command: '/bin/systemctl', args: ['enable', 'caboose-files.service', 'caboose-terminal.service', 'caboose-vsock-services.service'] })
  if (enabled.exitCode !== 0) throw new Error(`enable failed: ${enabled.stderr}`)
  await bootstrap.shutdown('bootstrap')
  const source = await host.start({ deskId: 'source', baseImage: disk, overlayPath: disk, memoryMb: 1024, vcpus: 2, network: { tapDevice: 'dsk932100', guestAddress: '172.30.92.2' } })
  if (process.env.TEMPLATE_CHECK_QUICK !== '1') {
    const version = await source.exec({ command: '/bin/cat', args: ['/usr/local/share/caboose/components.version'] })
    if (version.exitCode !== 0 || version.stdout.trim() !== required('TEMPLATE_CHECK_COMPONENT_VERSION')) throw new Error('Disposable source lacks the current complete component bundle')
    console.log('PASS disposable source component version')
  }
  const prepared = await source.exec({ command: '/usr/bin/python3', args: ['/usr/local/libexec/caboose-template', 'prepare'], timeoutMs: 90_000 })
  if (prepared.exitCode !== 0) throw new Error(`guest prepare failed: ${prepared.stderr}`)
  const bridgeScript = `import pathlib,subprocess
p=int(subprocess.check_output(['systemctl','show','--property=MainPID','--value','desk-vsock-bridge.service']))
for proc in sorted(pathlib.Path('/proc').glob('[0-9]*')):
 try:
  status=(proc/'status').read_text(); fields={line.split(':',1)[0]:line.split(':',1)[1].strip() for line in status.splitlines() if ':' in line}
  if int(proc.name)!=p and fields.get('PPid')!=str(p): continue
  print('pid',proc.name,'exe',(proc/'exe').resolve(),'argv',repr((proc/'cmdline').read_bytes()),'ppid',fields.get('PPid'),'uid',fields.get('Uid'),'cgroup',(proc/'cgroup').read_text().strip())
 except (OSError,ValueError): pass`
  const bridge = await source.exec({ command: '/usr/bin/python3', args: ['-c', bridgeScript] })
  console.log(`CHECK private bridge: ${bridge.stdout} ${bridge.stderr}`)
  console.log('PASS isolated template guest')
  await host.suspend('source')
  for (const file of [disk, ...['config.json', 'state.json', 'memory-ranges'].map(name => join(snapshot, name))]) await chmod(file, 0o400)
  const compatibility = { vmmVersion: 'v54.0', vmmPath: '/usr/local/bin/cloud-hypervisor', cpuSignature: await hostCpuSignature(), componentVersion: required('TEMPLATE_CHECK_COMPONENT_VERSION'), baseImagePath: required('TEMPLATE_CHECK_GOLDEN'), kernelPath: kernel, initramfsPath: initrd, attachmentPaths: [] }
  const quick = process.env.TEMPLATE_CHECK_QUICK === '1'
  if (!quick) await registerDeskTemplate(snapshot, disk, compatibility)
  async function startChild(id: string, tap: string, address: string, network: any) {
    await network.ensure({ tap, guest: address })
    const childDir = join(stage, id)
    let childMac = '', childCid = 0
    let initializedMachine: any
    const child = await host.start({ deskId: id, baseImage: disk, overlayPath: join(childDir, 'disk.raw'), memoryMb: 1024, vcpus: 2, network: { tapDevice: tap, guestAddress: address }, template: {
      async holdFence() {}, // This private network namespace has no external interface.
      async prepare(plan: any) {
        if (plan.hypervisor !== 'cloud-hypervisor') throw new Error('wrong hypervisor')
        childMac = plan.tap.mac; childCid = plan.vsock.cid
        const identity = { deskId: id, tap: plan.tap.device, mac: plan.tap.mac, vsockCid: plan.vsock.cid, vsockSocket: plan.vsock.socketPath }
        if (!quick) await forkDeskTemplate(snapshot, childDir, identity, compatibility)
        else {
          await mkdir(childDir)
          const childDisk = join(childDir, 'disk.raw')
          await copyFile(disk, childDisk, constants.COPYFILE_EXCL | constants.COPYFILE_FICLONE_FORCE)
          await chmod(childDisk, 0o600)
          const config = planTemplateConfig(JSON.parse(await readFile(join(snapshot, 'config.json'), 'utf8')), { ...identity, diskPath: childDisk })
          const target = join(childDir, `${id}.snapshot`)
          await pinTemplateMemory(snapshot, target, config)
          await writeFile(join(target, 'appkit-cpu-signature'), compatibility.cpuSignature)
          await writeFile(join(childDir, '.prepared'), '1\n')
        }
      },
      async verifyResume() {}, // This diagnostic does not re-park a child.
      async verifyPrepared(plan: any) {
        if (!quick) await verifyDeskTemplateFork(childDir, { deskId: id, tap: plan.tap.device, mac: plan.tap.mac, vsockCid: plan.vsock.cid, vsockSocket: plan.vsock.socketPath }, compatibility)
      },
      async initialize(machine: any) {
        initializedMachine = machine
        console.log(`CHECK ${id} schedule vsock refresh`)
        const refresh = await machine.request({ op: 'exec', command: '/usr/bin/python3', args: ['/usr/local/libexec/caboose-template', 'refresh-vsock'], timeoutMs: 30_000 })
        if (refresh.exitCode !== 0) throw new Error(`vsock refresh scheduling failed: ${refresh.stderr}`)
        const deadline = Date.now() + 60_000
        let ready = false
        while (Date.now() < deadline) {
          await new Promise(resolve => setTimeout(resolve, 500))
          try {
            const probe = await machine.request({ op: 'exec', command: '/usr/bin/python3', args: ['/usr/local/libexec/caboose-template', 'check-vsock', String(childCid)], timeoutMs: 5_000 })
            if (probe.exitCode === 0) { ready = true; break }
          } catch { /* The bridge reconnects after device reprobe. */ }
        }
        if (!ready) throw new Error('Guest vsock identity did not refresh')
        console.log(`PASS ${id} vsock CID refreshed`)
        const result = await machine.request({ op: 'exec', command: '/usr/bin/python3', args: ['/usr/local/libexec/caboose-template', 'reinitialize', childMac, String(childCid)], timeoutMs: 90_000 }, { timeoutMs: 95_000 })
        if (result.exitCode !== 0) throw new Error(`guest reset failed: ${result.stderr}`)
        console.log(`CHECK ${id} entropy and identity reset completed`)
        const restart = await machine.request({ op: 'exec', command: '/usr/bin/python3', args: ['/usr/local/libexec/caboose-template', 'restart-agent'], timeoutMs: 30_000 })
        if (restart.exitCode !== 0) throw new Error(`agent restart scheduling failed: ${restart.stderr}`)
        const previous = String(restart.stdout).trim().split('\n').at(-1) ?? ''
        if (!/^[0-9]+:[0-9]+$/.test(previous)) throw new Error('invalid agent identity')
        const agentDeadline = Date.now() + 60_000
        let restarted = false
        while (Date.now() < agentDeadline) {
          await new Promise(resolve => setTimeout(resolve, 500))
          try {
            const probe = await machine.request({ op: 'exec', command: '/usr/bin/python3', args: ['/usr/local/libexec/caboose-template', 'check-agent', previous], timeoutMs: 5_000 }, { timeoutMs: 10_000 })
            if (probe.exitCode === 0) { restarted = true; break }
          } catch { /* wait for the new private agent */ }
        }
        if (!restarted) throw new Error('guest agent did not restart')
        console.log(`PASS ${id} private agent restarted`)
        const gateway = address.replace(/\.2$/, '.1')
        const networkScript = `set -eu\ndev=$(ls /sys/class/net | grep -E '^(en|eth)' | head -n 1)\ntest -n "$dev"\nip addr flush dev "$dev"\nip addr add ${address}/24 dev "$dev"\nip link set dev "$dev" up\nip route replace default via ${gateway} dev "$dev"`
        const configured = await machine.request({ op: 'exec', command: '/bin/sh', args: ['-c', networkScript], timeoutMs: 20_000 })
        if (configured.exitCode !== 0) throw new Error(`guest network setup failed: ${configured.stderr}`)
      },
      async releaseFence() {
        if (!initializedMachine) throw new Error('Guest was not initialized')
        const result = await initializedMachine.request({ op: 'exec', command: '/usr/bin/python3', args: ['/usr/local/libexec/caboose-template', 'activate'], timeoutMs: 90_000 }, { timeoutMs: 95_000 })
        if (result.exitCode !== 0) {
          const journal = await initializedMachine.request({ op: 'exec', command: '/bin/journalctl', args: ['-u', 'caboose-terminal.service', '-n', '30', '--no-pager', '-o', 'short'], timeoutMs: 15_000 }, { timeoutMs: 20_000 })
          console.error(`CHECK bounded terminal journal:\n${journal.stdout || ''}\n${journal.stderr || ''}`)
          throw new Error(`guest activation failed: ${result.stderr}`)
        }
        // The namespace has no external interfaces; there is no host TAP fence to release.
      },
    } })
    return child
  }
  const first = await startChild('child', 'dsk932101', '172.30.93.2', networks[1])
  const second = await startChild('child2', 'dsk932102', '172.30.94.2', networks[2])
  async function identity(handle: any) {
    const result = await handle.exec({ command: '/usr/bin/python3', args: ['-c', "import os;print(open('/etc/machine-id').read().strip());print(os.urandom(32).hex())"] })
    if (result.exitCode !== 0) throw new Error('identity check failed')
    return result.stdout.trim().split('\n')
  }
  const [a, b] = await Promise.all([identity(first), identity(second)])
  if (a.length !== 2 || b.length !== 2 || a[0] === b[0] || a[1] === b[1]) throw new Error('child identities or random samples match')
  const write = await first.exec({ command: '/bin/sh', args: ['-c', 'printf child-one > /root/.caboose-template-probe && sync'] })
  const separate = await second.exec({ command: '/bin/sh', args: ['-c', 'test ! -e /root/.caboose-template-probe'] })
  if (write.exitCode !== 0 || separate.exitCode !== 0) throw new Error('child disks are not independent')
  const sourceInode = (await stat(join(snapshot, 'memory-ranges'))).ino
  for (const id of ['child', 'child2']) {
    const childDir = join(stage, id)
    const retired = (await readdir(childDir)).find(name => name.startsWith(`${id}.snapshot.source-`))
    if (!retired || (await stat(join(childDir, retired, 'memory-ranges'))).ino !== sourceInode) throw new Error('child memory source inode differs')
    let mapped = false
    for (const pid of (await readdir('/proc')).filter(name => /^\d+$/.test(name))) {
      try {
        const cmd = await readFile(`/proc/${pid}/cmdline`, 'utf8')
        if (!cmd.includes(join(runtime, `desk-${id}.api.sock`))) continue
        const maps = await readFile(`/proc/${pid}/maps`, 'utf8')
        mapped = maps.split('\n').some(line => line.includes('memory-ranges') && line.split(/\s+/)[4] === String(sourceInode))
      } catch { /* Processes may exit while /proc is inspected. */ }
    }
    if (!mapped) throw new Error(`${id} did not map the shared memory inode`)
  }
  console.log('PASS distinct child identities, random samples and disks; VMMs map the same memory inode')
} finally {
  await bootstrap.shutdown('bootstrap').catch(error => console.error('bootstrap cleanup:', error))
  for (const id of ids.reverse()) await host.destroy(id).catch(error => console.error(`cleanup ${id}:`, error))
  await networks[2]!.teardown({ tap: 'dsk932102', guest: '172.30.94.2' }).catch(error => console.error('network cleanup:', error))
  await networks[1]!.teardown({ tap: 'dsk932101', guest: '172.30.93.2' }).catch(error => console.error('network cleanup:', error))
  await networks[0]!.teardown({ tap: 'dsk932100', guest: '172.30.92.2' }).catch(error => console.error('network cleanup:', error))
}
