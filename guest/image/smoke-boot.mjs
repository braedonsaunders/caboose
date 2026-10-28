import { buildDeskLaunchPlan, createCloudHypervisorBackend, parseExecResult } from '@braedonsaunders/appkit-desk'
import { execFileSync } from 'node:child_process'
import { randomBytes } from 'node:crypto'
import { writeFileSync, rmSync } from 'node:fs'
import { join } from 'node:path'

const [disks, work] = process.argv.slice(2)
const token = randomBytes(32).toString('hex')
const tokenPath = join(work, 'token')
writeFileSync(tokenPath, token, { mode: 0o600 })
const snapshot = join(work, 'snapshot')
const opts = {
  deskId: 'caboose-smoke', vmmPath: '/usr/local/bin/cloud-hypervisor',
  kernelPath: join(disks, 'vmlinux'), initramfsPath: join(disks, 'initrd'),
  baseImagePath: join(disks, 'base.raw'), overlayPath: join(work, 'overlay.raw'),
  runtimeDir: work, snapshotDir: snapshot, vsockCid: 7910, tapDevice: 'cbsmoke',
  memoryMb: 2048, vcpus: 4, kernelCmdline: 'console=ttyS0 root=/dev/vda3 rw',
}
const backend = createCloudHypervisorBackend({ connectTimeoutMs: 180000 })
let machine
async function run(script) {
  const result = parseExecResult(await machine.request({ op: 'exec', command: '/bin/sh', args: ['-c', script], timeoutMs: 30000 }, { timeoutMs: 35000 }))
  if (result.exitCode !== 0) throw new Error(`guest command failed: ${result.stderr}`)
  return result.stdout
}
function info() {
  return execFileSync('xpra', ['info', 'ws://192.0.2.2:14500/', `--password-file=${tokenPath}`], { encoding: 'utf8', timeout: 30000 })
}
try {
  let start = performance.now()
  machine = await backend.boot(buildDeskLaunchPlan(opts))
  console.log(`Cold boot to guest agent: ${((performance.now() - start) / 1000).toFixed(2)} s`)
  await run(`set -e; dev=$(ls /sys/class/net | grep -E '^(en|eth)' | head -1); ip addr replace 192.0.2.2/30 dev "$dev"; ip link set "$dev" up; install -d -m 0755 /run/caboose; printf %s '${token}' > /run/caboose/xpra-token; chown caboose:caboose /run/caboose/xpra-token; chmod 0600 /run/caboose/xpra-token; systemctl start caboose-xpra.service`)
  await run("runuser -u caboose -- sh -c 'DISPLAY=:100 nohup xfce4-terminal >/tmp/caboose-terminal.log 2>&1 & DISPLAY=:100 nohup chromium --no-first-run about:blank >/tmp/caboose-chromium.log 2>&1 &'")
  let output = ''
  for (let i = 0; i < 30; i++) {
    await new Promise(resolve => setTimeout(resolve, 2000))
    try { output = info(); if (/terminal/i.test(output) && /chrom/i.test(output)) break } catch {}
  }
  if (!/terminal/i.test(output) || !/chrom/i.test(output)) throw new Error('Xpra info did not show both terminal and Chromium windows')
  console.log('Authenticated Xpra WebSocket info shows terminal and Chromium windows')
  await run('sync')
  start = performance.now()
  await machine.park(snapshot)
  machine = undefined
  console.log(`Park: ${((performance.now() - start) / 1000).toFixed(2)} s`)
  start = performance.now()
  machine = await backend.boot(buildDeskLaunchPlan({ ...opts, restore: true }), { onRestored: async () => rmSync(snapshot, { recursive: true, force: true }) })
  console.log(`Resume to guest agent: ${((performance.now() - start) / 1000).toFixed(2)} s`)
  output = info()
  if (!/terminal/i.test(output) || !/chrom/i.test(output)) throw new Error('Windows did not survive resume')
  console.log('Both windows survived resume')
} finally {
  if (machine) await machine.shutdown()
}
