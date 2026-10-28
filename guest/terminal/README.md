# Guest terminal service

`caboose-terminal.py` serves the owner's terminals: login shells on pseudo-terminals, one per
WebSocket, for caboose-host's `/v1/terminal` routes. It is Python 3 with `websockets` (Debian's
`python3-websockets`, which both guest images have and the components installer adds), and
runs as `caboose` on port 14701. The protocol is in
[`docs/architecture.md`](../../docs/architecture.md) § Terminal.

- **Authentication.** Every request must carry `Authorization: Bearer <token>`, where the
  token is the one the host writes to `/run/caboose/display-token`. The file is read on every
  connection, so a new token takes effect at once.
- **Sessions.** A connection to `/?cols=&rows=` starts a login shell (the user's shell, run as
  `-bash`) in the home with `TERM=xterm-256color`, `COLORTERM=truecolor` and the owner
  display's launch environment. `/?cols=&rows=&session=<id>[&offset=<n>]` reattaches. A
  session outlives its connection and ends when its shell exits or is hung up; at most 16
  exist, and a new one past that hangs up the one left unattached longest.
- **Replay.** Each session keeps its last 256 KiB of output and the state the replay may no
  longer carry: the DEC private modes for cursor keys, cursor visibility, the alternate
  screen, mouse reporting, focus events and bracketed paste, and the title (OSC 0 and 2).
- **Flow.** Output for an attached client is read only as fast as the client takes it, so
  a slow client slows the shell. With nobody attached, output is read into the replay, so
  the shell never blocks.
- **Programs.** `GET /start?cols=&rows=&argv=<base64url JSON list>` starts a session running
  that program (1–64 strings, the first an absolute path) instead of a login shell, with the
  same environment, and answers `{ "session": "<id>" }`; a client then attaches with
  `session=<id>`. The session ends when the program exits. The agent runner uses this for an
  agent's terminal sign-in on the phone.
- **Listing.** `GET /sessions` lists the sessions with their title, foreground program and
  its directory; `GET /hangup?session=<id>` hangs one up.

| Variable | Default | Meaning |
| --- | --- | --- |
| `CABOOSE_TERMINAL_TOKEN_FILE` | `/run/caboose/display-token` | The token file. |
| `CABOOSE_TERMINAL_PORT` | `14701` | The listening port. |
| `CABOOSE_TERMINAL_DISPLAY_ENV` | `/run/caboose/display.env` | The owner display's launch environment, given to each shell. |

The service listens on every interface inside the computer. Only the host reaches it: in the
microVM through the guest's private TAP address, in the container runtime on a port published
on the host's loopback (or, for a container created before the port existed, on the
container's own bridge address). Never publish port 14701 to a network: it is a shell.

## Install and run

Both guest images install the service as `/opt/caboose/terminal/caboose-terminal.py`, with
`caboose-terminal.service` (enabled) in the microVM; in the container,
`caboose-components-services` starts it. It is part of the guest components bundle
(`guest/components`), so the host installs and updates it in existing computers at wake.
Stopping the service hangs up every shell (`KillMode=process`, so what a shell started with
`nohup` or `setsid` keeps running).

## Test

- `test_logic.py` unit-tests the query, start and control-message parsing, the replay and its
  offsets, mode and title tracking, the shell's environment and the token check. The host's
  test suite runs it (`src/terminal-logic.test.ts`), or run `python3 guest/terminal/test_logic.py`.
- `check-service.py` runs the real service in Linux: a login shell, resize, detach and
  reattach from an offset, a replay with modes, a second client replacing the first, a
  4 MB burst, a bad control message, exit codes, hangup, a started program and the session
  cap. From the
  repository root, with Docker:

  ```sh
  docker run --rm -v "$PWD/guest/terminal:/checks:ro" debian:trixie-slim sh -c \
    'apt-get update -qq && apt-get install -y -qq python3 python3-websockets >/dev/null && python3 /checks/check-service.py'
  ```

- `apps/host/scripts/check-terminal.mjs` checks a running computer through the host (see
  [`apps/host`](../../apps/host/README.md#real-host-checks)).
