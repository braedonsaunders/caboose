# Guest file service

`caboose-files.py` is the computer's private file service: a Python 3 HTTP server, with no
packages beyond the standard library, that runs as `caboose` on port 14700 and serves
home-confined file operations for caboose-host's `/v1/fs` routes and shared files. The
protocol is in [`docs/architecture.md`](../../docs/architecture.md) § Files.

- **Authentication.** Every request must carry `Authorization: Bearer <token>`, where the
  token is the one the host writes to `/run/caboose/display-token`. The file is read on
  every request, so a new token takes effect at once.
- **Confinement.** Paths are relative to the home directory. Every path component is opened
  through directory file descriptors with `O_NOFOLLOW`, so a symbolic link never leads
  outside the home.
- **Changes.** `/changes` reports changes from Linux inotify through a bounded, per-process
  journal.

| Variable | Default | Meaning |
| --- | --- | --- |
| `CABOOSE_FILES_ROOT` | `/home/caboose` | The directory served. |
| `CABOOSE_FILES_TOKEN_FILE` | `/run/caboose/display-token` | The token file. |
| `CABOOSE_FILES_PORT` | `14700` | The listening port. |
| `CABOOSE_BRIDGE_RUNTIME` | `/run/user/<uid>` | Directory of agent-app bridge sockets. |

The service listens on every interface inside the computer. Only the host reaches it: in the
microVM through the guest's private TAP address, in the container runtime on a port published
on the host's loopback only. Never publish port 14700 to a network.

## Install and run

Both guest images install the service as `/opt/caboose/files/caboose-files.py`. The host
starts it at each wake after writing the token: `caboose-files.service` in the microVM
(installed, not enabled), `caboose-session start-files` in the container.

The service is part of the guest components bundle (`guest/components`), so the host
updates it in existing computers at wake. A container created without the port 14700
mapping must be recreated to enable it; the home volume is kept. Never publish port 14700
to the network: it is a private host-to-guest transport.

## Test

- `test_logic.py` unit-tests path validation, byte ranges, versions and change anchors. The
  host's test suite runs it (`src/fs-logic.test.ts`), or run `python3 guest/files/test_logic.py`.
- `python3 guest/files/test_parked_quiesce.py` checks parked Files freezer planning,
  recovery-control identity, bridge protection and rollback. The control plane accepts
  only the packaged root guest agent, its helper, systemd and the exact private vsock
  bridge listener and its validated socat children; unknown peers make the view unavailable.
  The freezer planner excludes only processes whose kernel status explicitly reports
  `Kthread: 1`; missing or ambiguous status fails closed. Filesystem freeze fences
  kernel filesystem writes.
- `check-service.py` runs the real service in Linux, including inotify and dirfd confinement.
  From the repository root, with Docker:

  ```sh
  docker run --rm -v "$PWD/guest/files:/checks:ro" python:3.13-slim python3 /checks/check-service.py
  ```

- `apps/host/scripts/check-fs.mjs` checks a paired computer through the public API (see
  [`apps/host`](../../apps/host/README.md#real-host-checks)).

### Private keyring provisioning

The host sends `POST /keyring` over the same authenticated private service connection,
with exactly 64 lowercase hex characters in the body. The endpoint serializes requests and
pipes the credential to `caboose-keyring` on stdin; it writes no credential file or request
log and returns only a fixed state with `Cache-Control: no-store`. The host filesystem
proxy allows only public file operations and cannot forward this endpoint. Run
`python3 guest/files/test_keyring_endpoint.py` for body, authorization, serialization and
error-redaction checks without starting Linux services.

### Private agent-app bridge

`POST /webview/<instance>` is a token-authenticated relay to the app instance's Unix
socket in the runtime directory. It accepts only a 32-character lowercase hex instance,
requires a bounded Content-Length and streams at most 96 MiB in each direction. The app
checks its display-session grant, document revision and declared capabilities. The host
exposes only its separately authenticated bridge route, not this guest endpoint. Run
`python3 guest/files/test_webview_endpoint.py` for authorization and request-bound checks.

## Host event receiver

`event_stream.py` serves the private authenticated `/events` long poll and
`/events/presence` phone lease endpoint alongside the existing Files and app webview
bridge routes. Queue records remain on disk until the host accepts them; bridge claims
remain until their response. Active task IDs and offsets come from the host, with strict
UUID and numeric validation and bounded output. See [guest events](../../docs/guest-events.md)
for channels, bounds, replay and lifecycle semantics.

Run `python3 -m unittest discover -s guest/files -p test_events.py` from the repository
root. Linux exercises inotify and process-descriptor behavior; portable unit checks can
run without starting Files or touching an owner's home.

On an isolated Linux checkout, `python3 guest/files/check-events.py` runs the real Files
service against a temporary synthetic home and token on loopback, checks delivery,
acknowledgements, watch retirement and presence fencing, and reports two five-second
idle samples plus publication latency. It terminates and waits for its own service in
`finally`. CPU ticks have kernel clock granularity; main-thread context switches are not
total wakeups. Instrumented select/poll wait completions report userspace wait wakeups
(including HTTP accept timeouts), with the overhead of writing one byte per completion. CPython audit events count Python fork/spawn/exec attempts; native extension
syscalls are outside that metric. No Docker or desktop session is required.
