# Caboose on a server

The same caboose-host as a personal install, on its own domain with HTTPS: the release's
host image behind [Caddy](https://caddyserver.com), which gets the Let's Encrypt certificate
and renews it. Phones and the console reach it at `https://<domain>` from anywhere.

```sh
curl -fsSL https://raw.githubusercontent.com/braedonsaunders/caboose/main/deploy/server/install.sh \
  | sudo bash -s -- --domain caboose.example.com --email you@example.com
```

`deploy/linux/install.sh --domain …` does the same thing. At the end, the installer prints the
address, the setup link while unclaimed, how to read the owner token, and a pairing QR code for the first iPhone.

## What you need

- A Linux server (amd64 or arm64) with `/dev/kvm`: bare metal, or a cloud VM type with nested
  virtualization. The installer checks for it.
- A domain (or subdomain) whose A record points at the server, and ports 80 and 443 open to
  the internet for the certificate and for phones. The installer checks the DNS against the
  server's public address, and checks that nothing else holds the ports.
- Docker Engine with Compose. The installer installs it from <https://get.docker.com> when it
  is missing.
- Enough memory and CPU for the computers that run at once. Each running computer uses the
  memory and vCPUs set for it (6 GiB and 4 vCPUs by default), and parked computers use only
  disk. `CABOOSE_MAX_RUNNING` caps how many run together; further wakes wait. A computer's
  disk grows as it is used, up to `CABOOSE_DISK_SIZE`.

## What it sets up

| Path | What |
| --- | --- |
| `/opt/caboose-server/compose.yaml`, `Caddyfile` | The stack, from this directory at the release's tag. |
| `/opt/caboose-server/.env` (0600) | Settings (below). Written once; a re-run changes only the domain and version, preserving the state directory. |
| `/opt/caboose-server/caddy-options/email.caddy` | The ACME account email, with `--email`. |
| `/data/caboose` | Every computer, its snapshots, and the host's state, including the generated owner token. |
| Docker volumes `caddy-data`, `caddy-config` | Caddy's certificates and ACME account. |

Only Caddy publishes ports (80, 443, and 443/udp for HTTP/3). The host listens only on the
compose network, `172.31.250.0/24`, and believes Caddy's forwarding headers from it
(`CABOOSE_TRUSTED_PROXIES`): sign-in attempts are counted per client address, not per
proxy, and the console's origin is `https://<domain>`. Caddy passes WebSockets and streams
through unbuffered, and adds HSTS.

## Settings

Edit `/opt/caboose-server/.env`, then run `docker compose -f /opt/caboose-server/compose.yaml up -d`.

| Variable | Default | Meaning |
| --- | --- | --- |
| `CABOOSE_DOMAIN` | required | The domain Caddy serves and gets a certificate for. The host names `https://<domain>` first in pairing links (`CABOOSE_PUBLIC_URL`). |
| `CABOOSE_VERSION` | `latest` | The release of `ghcr.io/braedonsaunders/caboose-host` to run. |
| `CABOOSE_STATE_DIR` | `/data/caboose` | Where computers and the host's state live. |
| `CABOOSE_OWNER_TOKEN` | generated | Set it to choose the owner token instead of using the generated one. |
| `CABOOSE_MEMORY_MB`, `CABOOSE_VCPUS` | `6144`, `4` | The size of a new computer. |
| `CABOOSE_MAX_RUNNING` | `4` | How many computers may run at once. |
| `CABOOSE_DISK_SIZE` | `400G` | The largest the computers' disk image may grow, when the state directory is not on XFS or Btrfs. |
| `CABOOSE_HOST_IMAGE` | the release | Run another host image, for instance one built from a checkout. |
| `CABOOSE_HTTP_PORT`, `CABOOSE_HTTPS_PORT` | `80`, `443` | The ports Caddy publishes. Let's Encrypt needs 80 and 443 to reach it. |
| `CABOOSE_PROXY_NETWORK` | `172.31.250.0/24` | The compose network's subnet, which the host trusts Caddy's forwarding headers from (`CABOOSE_TRUSTED_PROXIES`). Change it only if it collides with a network the server uses. |

mDNS is off on a server. Guests reach only the public internet (docs/architecture.md, Network
fencing).

## People and computers

Make a computer for each person under **Computers** in the console, then pair each person's
iPhone from that computer's **Phones** tab. A phone's token reaches only its own computer, and
the owner token reaches everything (docs/architecture.md, Computers and Authentication).


## Upgrade, back up, remove

- **Upgrade:** run the installer again with the new `--version`, or set `CABOOSE_VERSION` and run
  `docker compose -f /opt/caboose-server/compose.yaml pull && docker compose -f /opt/caboose-server/compose.yaml up -d`.
  Stopping the host parks every computer with its memory first, and they resume after the
  upgrade.
- **Back up:** stop the stack (`docker compose … stop`), copy `/data/caboose` and the
  `caddy-data` volume, then start it again. Never run two hosts on one state directory.
- **Remove:** `docker compose -f /opt/caboose-server/compose.yaml down`. Then delete
  `/data/caboose` and the volumes (`down -v`) if you no longer want the computers.

## Security

- The host container is privileged, for KVM, loop-mounted disks and the computers' TAP
  networking. Run it on a server you trust and keep it up to date.
- Computers are microVMs. Their network is fenced to the public internet: they reach neither
  the server, its private networks, nor cloud metadata addresses.
- Treat the owner token as the server's root password. Phones get their own revocable tokens
  through pairing codes, and no link or QR code ever carries a token.
- Wrong passwords are counted per client address, which Caddy forwards from the compose
  network; the host trusts no other peer's forwarding headers.

## Checks

`deploy/server/check.sh` runs shellcheck, validates the compose file (only Caddy publishes
ports, and `CABOOSE_DOMAIN` is required), validates the Caddyfile with and without an ACME
email, and runs an installer dry run.

`deploy/server/check.sh --e2e` also builds the host image from the checkout and runs the stack
on `https://localhost:18443` with Caddy's own certificate authority. It checks:
- the console over HTTPS;
- the API's token;
- the public URL in `/v1/host/reach`;
- a WebSocket upgrade through Caddy;
- that the host publishes no port of its own.

It has no `/dev/kvm`, so it does not wake a computer.
