import { describe, expect, it } from 'vitest'
import { isLoopback, networkActivity, networkBusy, parseProcNet, readNetworkActivity } from './network-activity.js'

const HEADER = '  sl  local_address rem_address   st tx_queue rx_queue tr tm->when retrnsmt   uid  timeout inode\n'
const row = (local: string, remote: string, state: string) => `   0: ${local} ${remote} ${state} 00000000:00000000 00:00000000 00000000  1000        0 12345 1 0000000000000000 100 0 0 10 0\n`

// Real encodings: 0.0.0.0:5432, 127.0.0.1:5173, 172.22.0.2:32400 and the peer 172.22.0.3:51000.
const TCP = HEADER
  + row('00000000:1538', '00000000:0000', '0A')
  + row('0100007F:1435', '00000000:0000', '0A')
  + row('020016AC:7E90', '00000000:0000', '0A')
  + row('020016AC:7E90', '030016AC:C738', '01')
  + row('0100007F:1435', '0100007F:D000', '01')
  + row('00000000:3918', '00000000:0000', '0A') // 14616, a Caboose port
  + row('020016AC:3918', '010016AC:C000', '01')
// [::]:8080, [::1]:3000, and an IPv4-mapped loopback listener on 8000.
const TCP6 = HEADER
  + row('00000000000000000000000000000000:1F90', '00000000000000000000000000000000:0000', '0A')
  + row('00000000000000000000000001000000:0BB8', '00000000000000000000000000000000:0000', '0A')
  + row('0000000000000000FFFF00000100007F:1F40', '00000000000000000000000000000000:0000', '0A')
// 0.0.0.0:5353 (mDNS), 0.0.0.0:27015 (a game server), 0.0.0.0:41000 (ephemeral), 127.0.0.1:8125.
const UDP = HEADER
  + row('00000000:14E9', '00000000:0000', '07')
  + row('00000000:6987', '00000000:0000', '07')
  + row('00000000:A028', '00000000:0000', '07')
  + row('0100007F:1FBD', '00000000:0000', '07')

describe('/proc/net parsing', () => {
  it('decodes IPv4 and IPv6 addresses, ports and states', () => {
    const tcp = parseProcNet(TCP, 'tcp')
    expect(tcp[0]).toEqual({ protocol: 'tcp', local: { address: '0.0.0.0', port: 5432 }, remote: { address: '0.0.0.0', port: 0 }, state: 0x0a })
    expect(tcp[3]).toMatchObject({ local: { address: '172.22.0.2', port: 32400 }, remote: { address: '172.22.0.3', port: 51000 }, state: 1 })
    const tcp6 = parseProcNet(TCP6, 'tcp')
    expect(tcp6.map(socket => socket.local.address)).toEqual(['0:0:0:0:0:0:0:0', '0:0:0:0:0:0:0:1', '0:0:0:0:0:ffff:7f00:1'])
  })
  it('skips malformed lines', () => {
    expect(parseProcNet(`${HEADER}garbage\n   1: 0100007F:ZZZZ 00000000:0000 0A\n   2: 01:1 00:0 0A\n`, 'tcp')).toEqual([])
    expect(parseProcNet('', 'udp')).toEqual([])
  })
  it('recognizes loopback addresses', () => {
    expect(['127.0.0.1', '127.3.4.5', '0:0:0:0:0:0:0:1', '0:0:0:0:0:ffff:7f00:1'].every(isLoopback)).toBe(true)
    expect(['0.0.0.0', '172.22.0.2', '0:0:0:0:0:0:0:0', '0:0:0:0:0:ffff:ac16:2'].some(isLoopback)).toBe(false)
  })
})

describe('network activity', () => {
  const sockets = [...parseProcNet(TCP, 'tcp'), ...parseProcNet(TCP6, 'tcp'), ...parseProcNet(UDP, 'udp')]
  it('lists reachable servers, leaving out loopback, Caboose, ephemeral and discovery ports', () => {
    expect(networkActivity(sockets).servers).toEqual([
      { protocol: 'tcp', address: '0.0.0.0', port: 5432 },
      { protocol: 'tcp', address: '0:0:0:0:0:0:0:0', port: 8080 },
      { protocol: 'udp', address: '0.0.0.0', port: 27015 },
      { protocol: 'tcp', address: '172.22.0.2', port: 32400 },
    ])
  })
  it('counts only connections from another machine to a server', () => {
    expect(networkActivity(sockets).connections).toBe(1)
  })
  it('uses the kernel ephemeral range it is given', () => {
    expect(networkActivity(sockets, [5000, 6000]).servers.map(server => server.port)).toEqual([8080, 27015, 32400, 41000])
  })
  it('is busy with an outside connection, or a server another machine can reach', () => {
    expect(networkBusy({ servers: [], connections: 0 }, true)).toBe(false)
    expect(networkBusy({ servers: [{ protocol: 'tcp', address: '0.0.0.0', port: 80 }], connections: 0 }, false)).toBe(false)
    expect(networkBusy({ servers: [{ protocol: 'tcp', address: '0.0.0.0', port: 80 }], connections: 0 }, true)).toBe(true)
    expect(networkBusy({ servers: [], connections: 2 }, false)).toBe(true)
  })
  it('reads every table in one guest command', async () => {
    const calls: string[][] = []
    const guest = { run: async (command: string, args: string[]) => {
      calls.push([command, ...args])
      return `@@ /proc/sys/net/ipv4/ip_local_port_range\n32768\t60999\n@@ /proc/net/tcp\n${TCP}@@ /proc/net/tcp6\n${TCP6}@@ /proc/net/udp\n${UDP}@@ /proc/net/udp6\n`
    } }
    const activity = await readNetworkActivity(guest)
    expect(calls).toHaveLength(1)
    expect(calls[0]!.slice(0, 2)).toEqual(['/bin/sh', '-c'])
    expect(activity.servers).toHaveLength(4)
    expect(activity.connections).toBe(1)
  })
})
