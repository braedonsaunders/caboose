# GPU Acceptance Apps launcher

These source artifacts expose the unchanged vkQuake/LibreQuake fixture through the
ordinary owner Apps list on one isolated acceptance computer. They are not part of
the guest component manifest or a released game. Nothing in this directory installs
itself. A successful preflight checks guest prerequisites only; it does not establish
phone execution or rendered game pixels.

`owner-display` starts the retained private compositor with its normal owner HOME,
Wayland socket, Xwayland, control socket, audio, device and display-environment behavior.
It adds the indexed private GPU sockets under an owner-only runtime directory. The
existing host still supplies `/run/caboose/display-token` and relays port 14600. The
existing Caboose debug app supplies the executor over that authenticated display
session with `CABOOSE_PRIVATE_GPU_INDEXED=1`. No standalone executor is involved.
Release apps and ordinary app launches without that debug environment cannot execute
this private GPU lane.

`launch.py` checks the owner seat, live control-socket peer, exact compositor path
and private socket arguments, vkQuake ELF hash, bundle launcher hash and ICD library hash. It prevents
duplicate game launches with an inherited flock, selects the ICD only for vkQuake,
and opens LibreQuake's start map at 640×480 with sound disabled. It uses native SDL
Wayland through the retained bundle's `launch.sh`, preserving its private library and
PulseAudio search paths plus the inherited `LD_LIBRARY_PATH`. The Linux dynamic loader
checks the ELF's transitive dependency resolution before either launch or `--check`
succeeds. Errors and game output go
to `~/.cache/caboose/quake-gpu-acceptance.log`; early errors also attempt an ordinary
desktop notification. Apps launch acceptance itself does not report successful GPU
execution. Socket files and the control peer do not prove an executor is attached.

## Staging boundary and prerequisites

Use only the isolated GPU Acceptance computer. The original owner computer and the
agent seat remain unchanged. Do not run the finite trial harness alongside this
topology: that harness replaces the owner compositor and stops it at trial completion.

Required existing artifacts inside the acceptance computer:

- `/opt/caboose-private-gpu-v4/bin/caboose-display` with indexed GPU support and normal
  Xwayland support plus its runtime dependencies;
- `/fixture/bundle`, complete with LibreQuake data, license notices and the unchanged
  executable hash recorded in `launch.py`;
- `/fixture/icd.json`, whose absolute `ICD.library_path` names the retained driver
  with the hash recorded in `launch.py`;
- the fixture's SDL2/Vulkan/audio-codec runtime dependency closure, either in a verified
  private dependency sysroot or explicitly selected installed-library mode;
- a matching signed debug Caboose app using the private v4 package, paired to this
  computer and launched with `CABOOSE_PRIVATE_GPU_INDEXED=1`.

The game hash and driver hash are pinned in the source. A different artifact requires
explicit provenance review and an updated pin. Neither game nor driver is downloaded
or built by this launcher. The complete bundle manifest is in the parent directory;
verify it before staging and preserve all notices. Runtime config writes may update
the writable game bundle as in the existing fixture.

## Install and wire the isolated owner

With these files copied to a private staging directory **inside the acceptance
computer**, the installation commands are:

```sh
install -d -o root -g root -m 0755 /opt/caboose-gpu-acceptance
install -o root -g root -m 0755 owner-display launch.py /opt/caboose-gpu-acceptance/
```

Create root-owned `/opt/caboose-gpu-acceptance/runtime.json` (mode 0644) with the
required `library_directory` field. Set it to the **actual verified absolute library
directory inside this container** from the retained dependency extraction, including
its `pulseaudio` child; for a sysroot mounted at `/fixture/deps`, the value is
`"/fixture/deps/usr/lib/x86_64-linux-gnu"`. The retained dependency report uses the
build-container path `/task/deps/usr/lib/x86_64-linux-gnu`; that path is not assumed
to exist in the acceptance computer. Use `{"library_directory": null}` only when
explicitly selecting installed runtime libraries. Missing configuration fails;
there is no guessed sysroot or implicit installed-library fallback. Any inherited
`CABOOSE_GAME_LIBRARY_DIR` must match this configuration. `--check` validates the
selected dependency resolution, but does not hash every installed library; the
dependency archive hashes and extraction provenance still need review at staging.

The container entrypoint `guest/container/caboose-session` currently calls
`caboose-display` for both seats. In a retained, test-only copy of that entrypoint,
inside `start_display`, select the executable by the existing port argument:

```bash
local display_binary=caboose-display
if [ "$port" = 14600 ]; then
  display_binary=/opt/caboose-gpu-acceptance/owner-display
fi
```

Replace only `setsid caboose-display --env-file` in that function with
`setsid "$display_binary" --env-file`. Retain the original entrypoint for rollback.
Install the reviewed copy at `/usr/local/bin/caboose-session` in the isolated test
container. The original `caboose-display` binary is untouched and the agent branch
continues using it. The wrapper does not append `--token-file`: the compositor defaults
to `/run/caboose/display-token`, and the current owner `start_display` call passes only
`--env-file`. Any explicit token option from the caller is forwarded once. Do not change
the image, host executable selection, guest component
manifest, or another computer. The wrapper receives the existing `--env-file
/run/caboose/display.env` argument; it must not receive the harness's `--no-xwayland`,
private HOME, private Wayland name, or fixture runtime directory.

Restart only that computer through the existing lifecycle after it is empty. Check
ordinary owner Xwayland, Apps listing, control readiness, token-authenticated display
connection, and the unchanged agent seat. Then, as the owner with the display's actual
environment, check the launcher:

```sh
runuser -u caboose -- env HOME=/home/caboose /bin/sh -c \
  'set -a; . /run/caboose/display.env; exec /opt/caboose-gpu-acceptance/launch.py --check'
```

Publish the desktop entry only after that check and a real app-session launch succeed:

```sh
install -o root -g root -m 0644 com.caboose.QuakeGPUAcceptance.desktop \
  /usr/local/share/applications/com.caboose.QuakeGPUAcceptance.desktop
```

Refresh Apps, launch **Quake (GPU Acceptance)** and verify actual pixels and input in
the ordinary Caboose owner window. Retain the game log, phone executor log and a
screenshot together. Test duplicate taps, game exit/relaunch and a computer cold
start. The private phone GPU lane has no established unattended fallback when the
phone disconnects; this entry is restricted to acceptance, not normal computers.

## Validation and removal

Local source checks need no build or device:

```sh
sh -n owner-display
python3 -c 'import ast, pathlib; ast.parse(pathlib.Path("launch.py").read_text())'
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s . -p 'test_*.py'
```

The dependency tests execute the unchanged bundle launch script with a temporary test
executable to compare its exact library search path against the preflight environment,
including PulseAudio, inherited paths, installed-library mode and invalid configuration.

Live checks above require the actual isolated host and phone. They have not been run
by preparing these files. To remove the integration, remove this desktop entry, restore
the retained original `caboose-session`, and restart only the empty acceptance
computer through its normal lifecycle. The unchanged fixture and private compositor
artifacts can remain for finite acceptance runs.
