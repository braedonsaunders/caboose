# caboose-host

Work in progress: the API, guest integration and real-machine end-to-end check
are not yet verified against a Caboose image. This package is not ready to run
as a persistent service or expose to clients.

Install Node 22 and pnpm, then from the repository root run `pnpm install`,
`pnpm --filter caboose-host typecheck`, and `pnpm --filter caboose-host test`.

The environment variables are listed in `.env.example`. The host needs access
to KVM, a Cloud Hypervisor binary, and a Caboose image containing `base.raw`,
`vmlinux`, and `initrd`. Networking creates a named TAP and configures IPv4
forwarding, masquerading and filter rules; it requires root or passwordless
sudo for `ip`, `iptables` and `sysctl`. The guest can access networks reachable
from the host. Use a dedicated trusted host and network namespace. HTTPS/WSS
must be provided by a trusted reverse proxy before traffic crosses a network;
the host service itself serves unencrypted HTTP/WebSocket.

The unverified user-service template is `systemd/caboose-host.service`. Set
`CABOOSE_HOST_DIR` to the absolute path of `apps/host` and `CABOOSE_NODE` to
the absolute Node executable in `~/.config/caboose/host.env`, in addition to the
variables in `.env.example`; set the file mode to 0600. A user service also
needs a running user systemd manager, KVM group access, and non-interactive
privileges for the network setup. `CABOOSE_BIND=0.0.0.0` listens on every IPv4
interface; the service does not terminate TLS.

`CABOOSE_OWNER_TOKEN=... apps/host/scripts/e2e.sh` uses the local Xpra client
to authenticate an Xpra hello over the relay, parks, resumes, and repeats.
Set `CABOOSE_URL` when testing a different host. This check is not yet validated
against the Caboose guest image.
