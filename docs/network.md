# Computers on the network

A container computer is a machine on the owner's network, like a Linux server on their
desk. It has its own name and address. Every server it runs, on any TCP or UDP port, is
reachable at that address by any app on any of the owner's devices, with no per-port
setup and no Caboose sign-in in front of it. Servers bring their own authentication, as they
would on a LAN. Reachability uses the owner's own Tailscale: the phone runs the Tailscale
app it already has, and Caboose adds no VPN to it.

```
 iPhone (Tailscale app) ── WireGuard ──▶ companion  caboose-<id>-net        computer  caboose-<id>
   Safari  http://dev-box.tail….ts.net:5173     tailscale0 100.x.y.z ─ DNAT ─▶ eth0 172.x.0.2
   Postgres app  dev-box…:5432                  (host-owned, own netns)         ├ Vite on ::1:5173
   Plex app  dev-box…:32400                     uplink: caboose-uplink          │   ◀─ caboose-ports on 172.x.0.2:5173
                                                                                ├ PostgreSQL on 127.0.0.1:5432
                                                                                │   ◀─ caboose-ports on 172.x.0.2:5432
                                                                                └ Plex on 0.0.0.0:32400
```

## Its own tailnet device

Each container computer gets a **companion**: a container the host owns, named after the
computer with `-net` appended (`caboose-owner-net`, `caboose-c-…-net`), from the official
Tailscale image (`CABOOSE_TAILSCALE_IMAGE`, pinned by the host). The companion runs
`tailscaled` with the kernel's TUN in a network namespace of its own. Its device on the
tailnet is named after the computer (`Dev Box` becomes `dev-box`), so its MagicDNS name is
`dev-box.<tailnet>.ts.net`, and renaming the computer renames the device.

- **Two networks.** The companion is on the computer's own bridge and on `caboose-uplink`
  (bridge `caboose-up0`), which carries its WireGuard traffic. Because the uplink is not
  fenced, a phone on the same Wi-Fi connects directly rather than through a relay.
- **Forwarding.** Everything that arrives on the companion's tailnet IPv4 address, on any TCP
  or UDP port and ICMP, goes to the computer's address on its bridge (DNAT), masqueraded so
  the replies return through the companion, so a server sees the companion's bridge address
  as its client. Caboose's
  own services, ports 14600–14799, are never forwarded.
- **IPv6.** The device has a tailnet IPv6 address too, but only IPv4 reaches the computer.
  The companion refuses IPv6 connections at once (TCP reset, ICMPv6 unreachable), so clients
  that try IPv6 first fall back to IPv4 without waiting.
- **Fence.** The computer can answer but can start nothing through the companion: not into
  the tailnet, not to the companion itself, and not on to the uplink. The companion's own
  rules drop everything else, and the computer gains no capability, device or credential.
  The node's keys are in the companion's volume (named like the companion), which the
  computer cannot see. On the host, the computer's fence is unchanged except for one rule
  that lets the companion's address open connections to the computer's address (see
  [architecture § Network fencing](architecture.md#network-fencing)).
- **Lifecycle.** The host creates and starts the companion after each wake, without holding
  up the wake, and points it at the computer's current address. The companion keeps running
  while the computer is parked, so the device stays on the tailnet. A server answers again
  once the computer wakes. Deleting the computer removes the device from the tailnet, then
  removes the companion and its volume. A failure is reported in the computer's status and
  never fails a wake.

### Joining the tailnet

The host's own Tailscale sign-in cannot add devices, so each computer joins by itself, in
one of three ways:

| `CABOOSE_TAILSCALE_…` | How a new computer joins | Device owner |
| --- | --- | --- |
| nothing (the default) | The app shows **Add to Tailscale** with the device's sign-in link; the owner opens it and approves in Safari. This happens once per computer, and the host stores nothing. | the person who signed in |
| `AUTHKEY` | A reusable, pre-authorized auth key tagged with `CABOOSE_TAILSCALE_TAGS`. Tailscale keys expire within 90 days; devices that already joined keep working. | the tags |
| `CLIENT_ID` and `CLIENT_SECRET` | An OAuth client with the *Auth Keys* (write) and *Devices: Core* (write) scopes and the tags. The host mints a single-use key that expires in five minutes for each new device, and removes the device when the computer is deleted. | the tags |

`CABOOSE_TAILSCALE_TAGS` defaults to `tag:caboose`; the tailnet policy must list the tag in
`tagOwners`. A key reaches the companion only through standard input, never on a command
line. A device signed in by a person is subject to Tailscale's key expiry, 180 days by default,
unless the owner disables it for that device in the admin console; when it expires the app
shows the sign-in link again. Computers on a host with several people each join the tailnet of
whoever signs them in, so each person reaches only their own. An auth key or OAuth client puts
every computer on the operator's tailnet.

**Who can reach it** is the tailnet's policy. A personal tailnet's default policy lets the
owner's devices reach the computer. With tags, a policy that keeps it to the owner is:

```json
{
  "tagOwners": { "tag:caboose": ["autogroup:admin"] },
  "grants": [{ "src": ["autogroup:owner"], "dst": ["tag:caboose"], "ip": ["*"] }]
}
```

`CABOOSE_TAILNET=off` turns companions off for the host; microVM computers have none.

## Its own address on the home network

On a Linux host with its own Ethernet, `CABOOSE_LAN_INTERFACE=<interface>` also gives every
container computer an address on the home network, as if it were plugged into the same
switch. Phones on the same Wi-Fi then reach it without Tailscale, and LAN discovery works.

- **The interface.** The host makes a macvlan on that interface, with a stable locally
  administered MAC derived from the computer, and moves it into the computer's network
  namespace as `lan0`. `CABOOSE_LAN_MODE=ipvlan` uses ipvlan L2 instead, for parents that
  refuse extra MACs (most Wi-Fi interfaces). Ipvlan devices share the parent's MAC, so the
  DHCP server must tell them apart by client ID.
- **The lease.** A helper container the host owns, named like the computer with `-lan`
  appended, joins the computer's namespace with only NET_ADMIN and NET_RAW. It runs
  BusyBox's DHCP client on `lan0`, sending the computer's name as its host name. The lease
  sets only `lan0`'s address and subnet: the computer's default route and DNS stay on its
  own bridge. The helper renews the lease while the computer is parked. After each wake the
  host checks `lan0` is in the computer's namespace, and sets it up again after a restart.
- **Its name.** `caboose-ports` answers mDNS on `lan0` for `<name>.local` (A records), so Safari
  and apps on the same network find `dev-box.local`. The computer's own servers can
  advertise their services over mDNS and SSDP too.
- **The fence on lan0.** Caboose's ports (14600–14799) are closed on `lan0`. The computer
  answers anything that reaches it and may send multicast and mDNS and SSDP replies, but it
  starts no other connection on the LAN unless the host sets `CABOOSE_GUEST_LAN=allow`. The
  rules are in the computer's namespace, which the computer cannot change, but root in the
  computer can still send raw frames on `lan0`. Giving a computer a LAN address puts it on
  the LAN, so only an operator can turn it on, for the whole host.
- **Not on WSL or macOS.** WSL's mirrored networking and macOS share no Ethernet a
  container can join, and the host refuses the setting there. Computers on those hosts use
  their tailnet device.

`network.lan` in the computer's status is `{ state: 'starting' | 'running' | 'error', address?,
name?, error? }`, where `name` is `dev-box.local`.

## Servers that listen only on loopback

Vite, Django, Rails, Jupyter and PostgreSQL listen on `127.0.0.1` or `::1` by default.
`caboose-ports` ([guest/ports](../guest/ports/README.md)) runs in the computer and makes them
reachable as a developer's desktop would, with no change to the server:

- For each TCP port that only loopback listens on, except Caboose's ports and the ephemeral
  range, it listens on the same port of the computer's own addresses and pipes each
  connection to the loopback server.
- HTTP requests arrive with `Host`, and a same-host `Origin` and `Referer`, set to
  `http://localhost:<port>`. Vite's `allowedHosts`, Django's `ALLOWED_HOSTS` in debug, Rails'
  `config.hosts` and Jupyter's local-host check therefore accept a request for
  `dev-box.<tailnet>.ts.net:5173`. WebSockets (Vite's HMR) and everything that is not HTTP pass
  as bytes.
- The host switches it on while the computer has an address of its own. The computer's
  `forwardLoopback` setting (**Share Localhost Servers** in the app) turns it off, and then
  loopback servers stay private to the computer.

The addresses are plain HTTP, as on a LAN. They are not a browser secure context, so service
workers and some browser APIs are unavailable on them.

## Not idle while a server runs

A computer parks after its idle time without leases. It is also kept awake (the lifecycle's busy
check, read from the computer's `/proc/net` tables) while either of these is true:

- **A server another machine can reach is running:** a TCP listener, or a bound UDP socket,
  on an address that is not loopback, while the computer has an address of its own (a
  running tailnet device or home network address).
  Forwarded loopback servers count. Caboose's ports, the ephemeral range and discovery
  protocols (mDNS, SSDP, LLMNR, NetBIOS) do not.
- **Another machine is connected:** an established TCP connection to one of the computer's
  servers from an address that is not loopback.

A running managed service keeps it awake too, and after a host restart the host wakes a
computer with services that start with it. The check runs each time the idle timeout passes, then every minute while the computer is busy.
The computer parks one full idle timeout after the check last found it busy. A check that fails
counts as idle. An open phone (a foreground control socket) already holds a lease. Servers keep
running with the app closed and the phone off: nothing in their path is on the phone or in the
app.

## How the owner finds it

`GET /v1/computer` carries `network`:

```ts
type ComputerNetwork = {
  tailnet?: {
    state: 'off' | 'starting' | 'needs-login' | 'needs-approval' | 'running' | 'error',
    name?: string,          // dev-box.tailnet.ts.net
    addresses?: string[],   // IPv4 first
    loginUrl?: string,      // https://login.tailscale.com/a/…, while it needs sign-in
    error?: string,
  },
  lan?: { state: 'starting' | 'running' | 'error', address?: string, name?: string, error?: string },
  // While it has an address: the servers another machine can reach, read at most every 5 s.
  servers?: Array<{ protocol: 'tcp' | 'udp', address: string, port: number }>,
}
```

The app's Computer settings has a **Network** section. It shows the tailnet name and IPv4
address, the home network name and address,
the running servers (web servers open in Safari, others show `name:port` to copy into their
app), the **Share Localhost Servers** switch, and the sign-in button while one is needed. A
change is broadcast as `computer.settings` on the control socket.

## Checks

```sh
CABOOSE_CHECK_IMAGE=caboose-computer:<tag> apps/host/node_modules/.bin/tsx apps/host/scripts/check-network.mts --vite --postgres --keep
node apps/host/scripts/check-network-client.mjs <name it prints> 8000,8001,5173,5432   # from another tailnet device
CABOOSE_CHECK_REMOVE=<suffix> apps/host/node_modules/.bin/tsx apps/host/scripts/check-network.mts
```

The first command makes a throwaway computer on its own fenced bridge and gives it a device
through the production companion. It prints the sign-in link and waits up to ten minutes,
unless an auth key or OAuth client is configured. It starts loopback and wildcard HTTP
servers, plus Vite and PostgreSQL with `--vite --postgres`, checks they are servers on the
computer's own address, and checks that the computer reaches neither the tailnet, nor its
companion, nor private ranges. The second command, run from another tailnet device, reaches
each server by name: the pages, Vite's module and HMR WebSocket, and PostgreSQL's password
request. It also checks that Caboose's ports are closed and that IPv6 refuses at once. It needs
Docker, `/dev/net/tun`, and root or `sudo -n` for the fence.
