# Guest loopback forwarder

`caboose-ports.py` makes a server that listens only on loopback reachable on the computer's
own address, as on a developer's desktop. Vite, Django, Rails, Jupyter and PostgreSQL bind
`127.0.0.1` or `::1` by default; with this service they answer on the computer's tailnet
name with no configuration. How the computer gets that address is in
[`docs/network.md`](../../docs/network.md).

It is Python 3 with the standard library only, runs as `caboose`, and is started by the
container services (`caboose-components-services`). It holds no port of its own.

- **What it forwards.** Twice a second it reads `/proc/net/tcp` and `/proc/net/tcp6`. Each TCP
  port that only loopback addresses listen on is forwarded, except Caboose's own services
  (14600–14799) and the kernel's ephemeral range (`ip_local_port_range`). It listens on the
  same port of every IPv4 address the computer has on an interface other than `lo`, and pipes
  each connection to `127.0.0.1`, or to `::1` when only IPv6 loopback listens. When the server
  stops, its forward stops within half a second; connections already open continue.
- **HTTP.** A connection that starts with an HTTP/1.x request has each request's `Host` set to
  `localhost:<port>`, and `Origin` and `Referer` too when they name the host the client used.
  Bodies (`Content-Length` or chunked) and responses pass unchanged. After an `Upgrade`
  (WebSockets, HMR) or `CONNECT`, and for anything that is not HTTP (TLS, PostgreSQL), bytes
  pass as they are.
- **On and off.** It forwards only while `/run/caboose/ports.json` is `{"forward": true}`. The
  host writes it: true while the computer has an address of its own and its `forwardLoopback`
  setting is not off.
- **Collisions.** While a port is forwarded, this service holds it on the computer's own
  address, so a program that then binds the same port on `0.0.0.0` fails with "address in use"
  until the loopback server stops. A port another program already holds on an external
  address is not forwarded and is tried again every 30 s.

| Variable | Default | Meaning |
| --- | --- | --- |
| `CABOOSE_PORTS_CONFIG` | `/run/caboose/ports.json` | The host's switch. |
| `CABOOSE_PORTS_PROC` | `/proc/net` | Where the socket tables are read. |

Tests, from the repository root (no root, network or Docker needed):

```sh
python3 guest/ports/test_caboose_ports.py
```

The live check that reaches a forwarded Vite server and PostgreSQL from another machine is
`apps/host/scripts/check-network.sh` ([host README](../../apps/host/README.md)).
