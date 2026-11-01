# App scopes

`caboose-scopes` gives every app the owner runs a cgroup v2 scope of its own, the way
systemd gives each desktop launch a transient `app-*.scope`, so an app's whole process
tree is known, accounted and ended together: Wine and its server, pressure-vessel and the
game under it, a Flatpak's bubblewrap sandbox, helpers that double-fork away from their
parent. It is the guest half of the task manager; the host serves it as
`/v1/running-apps` ([architecture.md](../../docs/architecture.md#running-apps)) and the
phone shows it as the Task Manager.

It runs on container computers. A microVM's hierarchy belongs to systemd, so the daemon
refuses to set up there and the host reports no running apps.

## Files

| File | Installed as | What it is |
| --- | --- | --- |
| `caboose-scopes` | `/opt/caboose/scopes/caboose-scopes`, linked from `/usr/local/bin` | The daemon and its command-line client |
| `scopecore.py` | `/opt/caboose/scopes/scopecore.py` | The pure logic: scope names, kernel file parsing, classification, the snapshot |
| `install.sh` | | Run by `guest/components/install.sh` for containers |
| `check.sh` | | The live check against a running computer (below) |

## The hierarchy

Inside the container's own cgroup namespace (`--cgroupns=private`, Docker's default on
cgroup v2):

```
/init.scope                        the container's init, root's services, docker exec
/owner.slice/session.scope         the owner's processes no app claims
/owner.slice/app-<key>-<n>.scope   one app
```

`<key>` is the desktop id without `.desktop` (`steam`), `steam_app_<id>` for a Steam game,
a window's class for a window that arrived without a launch, or `caboose-terminal` for a
phone terminal session; it is escaped as `systemd-escape` escapes unit names
(`firefox-esr` becomes `firefox\x2desr`). `<n>` counts up for the daemon's lifetime and
across its restarts. The memory, IO and pids controllers are enabled on `/` and
`/owner.slice`; CPU time comes from every cgroup's `cpu.stat` without the CPU controller,
so scheduling is unchanged.

`setup` empties the namespace root (cgroup v2 allows domain controllers only above empty
cgroups): root's processes go to `init.scope`, the owner's to the session scope. `docker
exec` then lands in `init.scope`: runc joins the container's init cgroup when its own
cgroup has controllers enabled.

The tree must be writable. Docker mounts it read-only unless the container is created with
`--security-opt writable-cgroups=true`, which the host passes to new computers. For a
computer created before that, the host bind-remounts the mount writable at each wake from a
one-shot privileged container in the computer's pid namespace (`nsenter --target 1 --mount
mount -o remount,bind,rw /sys/fs/cgroup`). `nsdelegate` keeps the computer inside its own
cgroup either way. Without a writable tree, `ensure` and `setup` exit 3 and say why.

## The daemon

`caboose-scopes ensure` starts it unless it runs (`--restart` replaces it after an update);
`guest/components/container-services.sh` runs it at every wake and `caboose-session start`
before the owner's display. It runs as root, which alone moves processes between cgroups.
Container root has no `CAP_SYS_PTRACE` and cannot read the owner's command lines and
environments, and the compositor's control socket serves only its own user, so a forked
observer that has dropped to the owner reads those and answers over a socket pair.

Once a second while someone has listed in the last 30 s, else every 3 s, it moves the
owner's processes out of `init.scope` into the session scope, then classifies; the first
matching rule wins (`scopecore.classify`):

1. Steam's game reaper (`reaper SteamLaunch AppId=N --`) and its tree: a scope for game N,
   named from `steamapps/appmanifest_N.acf`.
2. Children forked while a split was being made, left in the scope it came from, follow
   their parent for 5 s.
3. A phone terminal session (a child of `caboose-terminal.py`): a scope of its own.
4. In the session scope, processes a launch marked through their environment
   (`CABOOSE_DESKTOP_ID`, else GLib's `GIO_LAUNCHED_DESKTOP_FILE`, with
   `GIO_LAUNCHED_DESKTOP_FILE_PID`): one scope per launch. This adopts apps that started
   before the daemon, and those another app launched through GLib.
5. A toplevel window (from the owner display's control socket `windows`) whose process is
   in the session scope or a terminal session's scope, or in an app scope when that process
   runs on a terminal under a windowed process of the scope that is not on that terminal (a
   program run from a terminal app): the window's process and descendants, a scope of its
   own.

A move takes a process tree within one scope, then twice more takes children of moved
processes forked meanwhile. Dock launches need none of this: `guest-apps.py` asks for its
scope (`{"op":"scope"}`) before GLib starts the app, so the app is born in it. Empty scopes
are removed. Metadata survives a daemon restart in `/run/caboose/scopes/state.json`; the
cgroups themselves say which scopes exist.

Each sample reads per scope `cpu.stat` (`usage_usec`), `memory.current` less
`memory.stat`'s `inactive_file`, and `io.stat` summed over devices, and per process
`/proc/<pid>/stat` and `statm`. GPU use is the private GPU broker's per-process
`usage.json` ([gpu-live.md](../../docs/gpu-live.md#applications)) matched by pid and start
time. An app's windows are the owner display's toplevels and dialogs whose process (the
control socket's `pid`, the same the display protocol reports) is in its scope.

## Requests

`/run/caboose/scopes.sock` (mode 0666) takes one JSON line and answers one, `{"ok": true,
"result": …}` or `{"ok": false, "error": CODE, "message": …}`, to root and the owner only
(`SO_PEERCRED`):

| Request | Result |
| --- | --- |
| `{"op":"list"}` | The snapshot: architecture.md's `/v1/running-apps` listing |
| `{"op":"scope","desktopId":ID}` | Moves the asking process into a new scope for that entry → `{scope}` |
| `{"op":"quit","scope":S}` | Asks each toplevel and dialog of the app to close (`close ID` on the control socket) → `{closed}`; `no-windows` when it has none |
| `{"op":"force-quit","scope":S}` | SIGTERM and SIGCONT to every process, `cgroup.kill` after 5 s → `{ended, killed}` once empty, at most 2 s later |
| `{"op":"kill","scope":S}` | `cgroup.kill` → `{ended, killed: true}` |

Error codes: `invalid`, `unknown` (no such scope), `forbidden` (the session scope),
`no-windows`, `gone`, `failed`. The client commands print the answer as one JSON line and
exit 0 whatever it says, so a caller that only sees stdout on success reads why;
`unavailable` means the daemon is not running.

```
caboose-scopes list
caboose-scopes quit 'app-firefox\x2desr-3.scope'
caboose-scopes force-quit 'app-steam-1.scope'
caboose-scopes kill 'app-steam_app_620-4.scope'
caboose-scopes run org.example.App.desktop -- COMMAND [ARG...]   # run something in a new scope
```

## Tests

```
python3 -m unittest discover -s guest/scopes -p 'test_*.py'
```

`check.sh` exercises a running container computer through `docker exec`: the hierarchy,
a scoped process tree with a double-forked child, a fake Steam reaper split into its game's
scope, Force Quit of a tree and of one that ignores SIGTERM, Kill, and the refusal to end
the session scope. With `--window` it also opens a GTK window on the owner's display from
outside any app, checks it gets a scope of its own with that window, and quits it politely.
It cleans up what it started.

```
guest/scopes/check.sh caboose-owner            # or caboose-c-<id>
guest/scopes/check.sh caboose-owner --window   # a window appears on the owner's display briefly
```
