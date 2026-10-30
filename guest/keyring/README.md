# Owner keyring

`caboose-keyring` initializes an empty GNOME Keyring store with a nonempty host-generated
password, or unlocks the existing login collection with that password. It runs as uid 1000
and uses the owner's persistent session bus. It adopts the existing Secret Service through
standard D-Bus activation and sends GNOME’s PAM unlock request to its control socket after verifying the peer PID
against the D-Bus owner. It never starts an unlock subprocess, replaces a daemon, deletes keyrings, changes a password,
or selects a plaintext browser password store. It does not persist the supplied password.

The host supplies 32 random bytes encoded as 64 lowercase hex characters on stdin. One
trailing newline is accepted for a private credential file. Keep that credential in a
mode-0600 file in the computer's private host state and include it in protected backups.
Do not place it in a command argument or environment variable. For an operator bootstrap,
pipe that file into `docker exec -i -u caboose COMPUTER /usr/bin/python3 /opt/caboose/keyring/caboose-keyring`.
Install the helper first; the guest requires `python3-gi` and `gnome-keyring`.

The helper prints only a fixed JSON state: `ready` (exit 0), `migration-required` (exit 3),
or `unavailable` (exit 1). It serializes invocations with a runtime file lock. An unlocked
existing default collection is usable without modification. A locked login/default pair
requires its current password; other existing collections or ambiguous aliases require an
explicit operator migration. A new random password cannot decrypt an old keyring. No
migration or credential reset occurs automatically.

Run `python3 guest/keyring/test_keyring.py` for the creation and preservation policy tests.
Real service checks require Debian 13: initialize an empty disposable home; store a test
secret; repeat the helper and browser launch; freeze/resume; cold restart with the same host
credential; verify the original secret and an unlocked default collection each time. A wrong
credential after cold boot must return `migration-required` and leave stored files intact.
The helper addresses the owner bus only; the agent seat has a separate session bus.

Both image builders and existing-computer updates install the helper through
`guest/components/install.sh`. After each wake the host provisions through the private Files
service and checks readiness before launching owner applications. The host's saved
`keyring-secret` is reused unchanged; a missing credential cannot recover an existing locked
store. GNOME Keyring remains attached to the persistent owner bus through repeated launches
and memory park. No daemon restart occurs during component upgrades.

For the real-service scripted check, copy `check.py` into the guest and run it as `caboose`,
piping the host's private credential through stdin exactly as for the helper. Supply a
unique random 32-character lowercase hex check ID (a test label, not a credential):

```
python3 /tmp/keyring-check.py seed CHECK_ID
python3 /tmp/keyring-check.py verify CHECK_ID
python3 /tmp/keyring-check.py cleanup CHECK_ID
```

Run `verify` after repeated owner browser launches, after park/wake, and after a cold boot.
It verifies the same synthetic secret and checks two provisioning calls retain the daemon
and produce no Secret Service prompt. `cleanup` deletes only the item tagged with that
unique check ID. Inspect the actual browser windows as well: a loaded page and no GCR dialog
are separate checks from secret storage. Do not lock or reset a live user's collections as
a test; wrong-password checks belong in a disposable computer.

## Agent credential routing

The agent bus uses `/opt/caboose/keyring/agent-bus.conf` and a private activation
service directory. Secret Service activation starts `secret-forwarder.py`, not a
second keyring writer. Installed system application activators, including accessibility and portals, are copied
into that directory except keyring/KWallet writers. User-home registrations are not inherited;
new system registrations enter it on the next component install. Reinstallation removes
stale or newly blocked managed registrations and atomically replaces each allowed file.
KWallet is not forwarded: it is a different API and is not a second credential backend.

The forwarder accepts only the Secret Service object subtree and its standard interfaces.
It authenticates agent clients and the canonical service as the current Unix uid using
the bus's EXTERNAL authentication and credential queries. Each agent D-Bus sender gets
its own upstream bus connection, preserving Secret Service cryptographic session ownership.
Replies retain their D-Bus types, object paths and caller serials; directed signals return
to that client. Client disconnection closes its upstream sessions. Backend disappearance
terminates the forwarder so stale sessions cannot be reused with another daemon. No other
agent D-Bus traffic is redirected to the owner bus. Both seats retain the existing shared
Unix-user trust model; this does not establish a credential permission boundary between them.

An agent `Prompt.Prompt` call returns
`org.caboose.Secret.Error.InteractionRequired`: the owner must unlock or approve the
operation interactively, then the agent retries it. The forwarder never accepts a prompt,
reads keyring files, dumps unlocked secrets, or logs request bodies/backend diagnostics.
Credential calls have a ten-second timeout, with at most 64 upstream clients and 128
queued and in-flight requests combined, admitted before main-loop dispatch. The host's existing canonical keyring preparation remains unchanged.

Existing running agent buses with the old configuration require an explicit restart.
Seat startup checks the live bus daemon's configuration and fails without restarting it
or resetting credentials. Component installation alone does not change a running bus.

Run `python3 guest/keyring/test_forwarder.py` on Linux with `python3-gi` and `dbus-daemon`.
It creates two disposable buses and a synthetic Secret Service, tests concurrent client
sessions, object routing, cross-client rejection, directed signals, prompt refusal and
exclusive service ownership and proxy crash/restart, and reaps the buses. This proves the forwarding API path;
it does not claim a real browser sign-in, GNOME unlock dialog, or cold-boot acceptance test.

Run `python3 guest/keyring/test_install_services.py` for synthetic activation-directory
reconciliation and symlink rejection. The forwarding harness also submits 1,024 concurrent
calls with main-loop dispatch held, checking that only 128 callbacks are admitted and that
rejected/scheduling-error paths release their admission slots.

### Disposable integrated acceptance

`check-dual-seat.py` runs against an already-built, integrated Debian Caboose container
image. It does not build, pull or install dependencies. Required image contents are the
matching compositor/probe and component bundle, Chromium with its sandbox enabled,
GNOME Keyring, dbus-daemon, python3-gi, python3-websockets, sudo/runuser and the normal
Caboose session scripts. The host requires Docker and Python 3; the checked-in guest
seccomp policy permits Chromium's namespace sandbox. No GPU or device mounts are used.

After reserving the resource slot, run from the reviewed checkout on the Linux worker:

```
python3 guest/keyring/check-dual-seat.py \
  --image sha256:FULL_IMMUTABLE_LOCAL_IMAGE_ID \
  --seccomp guest/container/caboose-seccomp.json
```

The driver uses two sequential containers, each bounded to 180 seconds, 2 CPUs, 2 GiB RAM,
256 PIDs, 256 MiB shared memory, private tmpfs runtime/temp directories and no network.
It mounts only this test directory read-only and a fresh, uniquely named synthetic home
volume with image-home copying disabled. It refuses a nonempty seed home. The synthetic
keyring password travels only through stdin and is never printed or placed in arguments.
The volume survives the transition between the two containers and is removed afterward;
no owner profile, display, device or service volume is accepted.

The seed phase starts both displays concurrently, opens one Chromium on each seat, checks
seat-specific synthetic cookies/localStorage via window titles, and repeats an agent
launch while verifying the owner's window remains alone. Chromium closes through its
private loopback debugging endpoint for a clean profile shutdown. The next cold container
verifies the same profile markers and synthetic canonical GNOME item. Both seats retrieve
the same synthetic credential, and exactly one GNOME keyring writer must exist. The driver
removes each container and checks its absence on success, failure or timeout, then removes
the synthetic volume. This is a scripted acceptance check, not an executed-result claim;
Firefox/Code-specific GUI checks and real account sign-in are outside this script.

The driver also accepts `--overlay-source PATH` with a read-only source export and newly
compiled binaries under `out/`. In that mode `install-acceptance-overlay.sh` installs only
the seat/keyring components inside each bounded test container before acceptance starts.
This avoids a Docker image commit and retains the same 180-second per-container cap.
The source commit, source manifest, artifact hashes and base image ID identify the tested
combination. It does not run the full component installer or stamp `components.version`.
