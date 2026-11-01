import { describe, expect, it, vi } from 'vitest'
import { LAN_SCRIPT, LanAddress, lanConfig, lanMac } from './lan.js'
import { TAILSCALE_IMAGE } from './tailnet.js'

describe('home network configuration', () => {
  it('is off unless the host shares an interface, and only on a Linux host of its own', () => {
    expect(lanConfig({}, 'linux', () => '6.8.0')).toEqual({ mode: 'off' })
    expect(lanConfig({ CABOOSE_LAN_INTERFACE: 'eno1' }, 'linux', () => '6.8.0')).toEqual({ mode: 'macvlan', interface: 'eno1', image: TAILSCALE_IMAGE, allowOut: false })
    expect(lanConfig({ CABOOSE_LAN_INTERFACE: 'wlp2s0', CABOOSE_LAN_MODE: 'ipvlan', CABOOSE_GUEST_LAN: 'allow' }, 'linux', () => '6.8.0')).toMatchObject({ mode: 'ipvlan', allowOut: true })
    expect(() => lanConfig({ CABOOSE_LAN_INTERFACE: 'eth0' }, 'linux', () => '6.6.87.2-microsoft-standard-WSL2')).toThrow(/WSL/)
    expect(() => lanConfig({ CABOOSE_LAN_INTERFACE: 'en0' }, 'darwin', () => '')).toThrow(/Linux/)
    expect(() => lanConfig({ CABOOSE_LAN_INTERFACE: 'eth0; rm -rf' }, 'linux', () => '')).toThrow(/interface name/)
    expect(() => lanConfig({ CABOOSE_LAN_INTERFACE: 'eth0', CABOOSE_LAN_MODE: 'bridge' }, 'linux', () => '')).toThrow(/macvlan/)
  })
  it('gives each computer a stable, locally administered unicast MAC', () => {
    const mac = lanMac('caboose-c-0123456789')
    expect(mac).toMatch(/^[0-9a-f]{2}(:[0-9a-f]{2}){5}$/)
    expect(parseInt(mac.slice(0, 2), 16) & 0x03).toBe(0x02)
    expect(lanMac('caboose-c-0123456789')).toBe(mac)
    expect(lanMac('caboose-owner')).not.toBe(mac)
  })
  it('fences lan0: never Caboose’s ports, and nothing started outward but discovery', () => {
    expect(LAN_SCRIPT).toContain('-A CABOOSE-LAN-IN -p tcp --dport 14600:14799 -j DROP')
    expect(LAN_SCRIPT).toContain('$t -A CABOOSE-LAN-OUT -j REJECT')
    expect(LAN_SCRIPT).toContain('iptables -I CABOOSE-LAN-OUT 1 -d 224.0.0.0/4 -p udp -j RETURN')
    expect(LAN_SCRIPT).toContain('exec udhcpc -f -i lan0 -x hostname:"$CABOOSE_HOSTNAME"')
    // The lease sets only lan0's address: no default route, no DNS.
    expect(LAN_SCRIPT).not.toMatch(/route add|resolv\.conf/)
  })
})

function fake(options: { helper?: 'running' | 'missing'; lan0?: boolean; lease?: boolean } = {}) {
  const calls: string[][] = []
  const host: string[][] = []
  let helper = options.helper ?? 'missing', lan0 = options.lan0 ?? false
  const lease = options.lease ?? true
  const docker = vi.fn(async (args: string[]) => {
    calls.push(args)
    if (args[0] === 'inspect' && args[2] === '{{.State.Status}}') { if (helper === 'missing') throw new Error('No such object'); return 'running\n' }
    if (args[0] === 'inspect' && args[2] === '{{.State.Pid}}') return '4242\n'
    if (args[0] === 'exec' && args.includes('/sys/class/net/lan0')) { if (!lan0) throw new Error('exit 1'); return '' }
    if (args[0] === 'exec' && args.includes('addr')) { if (!lease || helper === 'missing') throw new Error('no'); return '3: lan0    inet 192.168.68.40/22 brd 192.168.71.255 scope global lan0\n' }
    if (args[0] === 'run') { helper = 'running'; lan0 = true; return 'id' }
    if (args[0] === 'rm') { helper = 'missing'; return '' }
    return ''
  })
  const privileged = vi.fn(async (command: string, args: string[]) => { host.push([command, ...args]); return '' })
  return { docker, privileged, calls, host }
}

describe('a computer’s home network address', () => {
  const base = { config: { mode: 'macvlan' as const, interface: 'eno1', image: TAILSCALE_IMAGE, allowOut: false }, computer: 'caboose-c-0123456789', slot: 7, hostname: () => 'dev-box' }
  it('moves a macvlan into the computer, starts the helper in its namespace, and reports the lease', async () => {
    const { docker, privileged, calls, host } = fake()
    const lan = new LanAddress({ ...base, docker, privileged })
    expect(await lan.ensure()).toEqual({ state: 'running', address: '192.168.68.40', name: 'dev-box.local' })
    expect(host).toContainEqual(['ip', 'link', 'add', 'link', 'eno1', 'name', 'cbl7', 'address', lanMac('caboose-c-0123456789'), 'type', 'macvlan', 'mode', 'bridge'])
    expect(host).toContainEqual(['ip', 'link', 'set', 'cbl7', 'netns', '4242'])
    const run = calls.find(args => args[0] === 'run')!
    expect(run).toEqual(expect.arrayContaining(['--network', 'container:caboose-c-0123456789', '--cap-drop', 'ALL', 'CABOOSE_LINK=cbl7', 'CABOOSE_HOSTNAME=dev-box', 'CABOOSE_LAN_OUT=deny']))
  })
  it('leaves a working helper alone at the next wake', async () => {
    const { docker, privileged, calls, host } = fake({ helper: 'running', lan0: true })
    const lan = new LanAddress({ ...base, docker, privileged })
    expect((await lan.ensure()).state).toBe('running')
    expect(host).toEqual([])
    expect(calls.some(args => args[0] === 'run')).toBe(false)
  })
  it('replaces a helper left in the namespace of a computer that restarted', async () => {
    const { docker, privileged, calls } = fake({ helper: 'running', lan0: false })
    const lan = new LanAddress({ ...base, docker, privileged })
    expect((await lan.ensure()).state).toBe('running')
    expect(calls).toContainEqual(['rm', '-f', 'caboose-c-0123456789-lan'])
    expect(calls.some(args => args[0] === 'run')).toBe(true)
  })
  it('reports a missing lease and errors instead of throwing', async () => {
    vi.useFakeTimers()
    try {
      const { docker, privileged } = fake({ lease: false })
      const lan = new LanAddress({ ...base, docker, privileged })
      const result = lan.ensure()
      await vi.advanceTimersByTimeAsync(31_000)
      expect(await result).toEqual({ state: 'error', error: 'No DHCP lease on eno1 after 30 s' })
    } finally { vi.useRealTimers() }
    const failing = new LanAddress({ ...base, docker: async () => { throw new Error('daemon down') }, privileged: async () => '' })
    expect(await failing.ensure()).toEqual({ state: 'error', error: 'daemon down' })
  })
  it('uses ipvlan without a MAC of its own', async () => {
    const { docker, privileged, host } = fake()
    await new LanAddress({ ...base, config: { ...base.config, mode: 'ipvlan' }, docker, privileged }).ensure()
    expect(host).toContainEqual(['ip', 'link', 'add', 'link', 'eno1', 'name', 'cbl7', 'type', 'ipvlan', 'mode', 'l2'])
  })
})
