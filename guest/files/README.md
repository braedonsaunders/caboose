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
