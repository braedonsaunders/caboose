# WLCS for caboose-display

[WLCS](https://github.com/canonical/wlcs) is Mir's Wayland conformance suite: a test runner
that loads a compositor integration, starts the compositor through it, and drives it as a
client with real Wayland requests while the integration injects pointer and touch input.
`caboose_wlcs.c` is the integration for caboose-display.

| File | What |
| --- | --- |
| `caboose_wlcs.c` | The adapter, `libcaboose_wlcs.so`: one WLCS display server is one `caboose-display` process |
| `expected-failures.txt` | The WLCS tests that still fail, in groups with the reason for each |
| `../scripts/check-wlcs.py` | Builds the adapter, runs WLCS, and compares the failures with the list |

## Run

In the runtime image (the `Dockerfile` in `guest/display` installs `wlcs`):

```sh
guest/display/scripts/dev.sh cargo build -p caboose-display
guest/display/scripts/dev.sh python3 scripts/check-wlcs.py            # the whole suite
guest/display/scripts/dev.sh python3 scripts/check-wlcs.py --filter 'XdgPopupTest.*'
```

`--bin` (or `CABOOSE_DISPLAY_BIN`) names the compositor binary, `target/debug/caboose-display`
by default. `CABOOSE_WLCS_LOGS=DIR` keeps each server's log in `DIR`, named by its runtime
directory's suffix. The whole suite is 1,160 tests and takes about 5 minutes, much of it WLCS's 10 s wait in each test
that fails. The check exits 0 when every failure is on the list and every listed pattern still
matches a failure; a test that starts passing must come off the list. A run against this
compositor passes 421 tests, fails the 61 listed, and skips 678 that need protocols it does not
advertise (layer shell, wl_shell, xdg-shell v6, foreign toplevel).

## How the adapter works

- **Start and stop.** `start` makes a private runtime directory, runs `caboose-display --no-auth
  --no-xwayland --no-audio --no-games --no-devices` in it and waits for the launch environment
  file. `stop` ends it with SIGTERM and removes the directory, so no test sees another's state.
- **Clients.** `create_client_socket` connects to the compositor's Wayland socket. The
  compositor counts connections to its socket and the control socket's `windows` lists each
  window's connection (`client`) and its root surface's id in it (`wl_surface`), which is how
  `position_window_absolute` finds the window a client's `wl_surface` made.
- **Windows.** `place ID X Y` on the control socket puts a toplevel at a position in the
  compositor's logical space, as the phone's `configure` does in display pixels.
- **Input.** The pointer is `move`, `motion` (with relative motion), `press` and `release` on the
  control socket, in logical coordinates, which are WLCS's compositor coordinates; a move over
  no window leaves the window the pointer was over. Touch is `touch SLOT PHASE X Y` (WLCS
  declares touch coordinates `wl_fixed_t` but passes whole pixels). All of it
  goes through the compositor's own pointer and touch handling, as the phone's does. WLCS
  has no keyboard interface.
- **Pacing.** A seat no phone watches releases frame callbacks once a second, so the adapter
  sends `settle` every 8 ms, as a display refreshing at 60 Hz would.
- **What WLCS runs.** The adapter's descriptor is the compositor's own registry, so WLCS skips
  the tests of every protocol the compositor does not advertise (layer shell, foreign
  toplevel, wl_shell, xdg-shell v6...) instead of failing them.

The control socket commands are documented in `compositor/src/control.rs`.
