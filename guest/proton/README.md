# Proton modules

Caboose runs Windows games with GE-Proton. This directory rebuilds the modules of a
GE-Proton release that Caboose changes, from GE's own sources with GE's own patches plus
the patches here. Everything else in the release is used as GE ships it.

| Patch | Module | What it fixes |
| --- | --- | --- |
| `win32u-monitor-dpi-ratio.patch` | `win32u.so` (x86_64 and i386) | `monitor_get_dpi()` packs a display's physical size over its current size, times its DPI, into 16 bits each, and asserted that it fits. After a mode change the two sizes can share no factor: a phone turning from 1338x911 to 932x1356 while a game runs gives 1356 × 96 over 911, and every Wine process that then asked for a DPI ended (`sysparams.c:2884: monitor_get_dpi: Assertion 'num * dpi / d < 65536' failed`). The ratio is now reduced and halved until it fits, and `get_monitor_dpi()` / `get_monitor_from_rect()` unpack it with `round_fractional_dpi()` instead of returning the packed `(den << 16) \| num` bitfield to `GetDpiForMonitor`. |
| `ntdll-fsync-alert-fd.patch` | `ntdll.so` (x86_64 and i386) | When `fsync` is enabled, `get_inproc_alert_fd()` stores the thread's `fsync_shm_idx` in `alert_fd` (`TEB+0x394` / `0x230`) rather than a file descriptor, but `pthread_exit_wrapper()` unconditionally called `close(alert_fd)`, closing whichever fd in the process matched that index on thread exit. Now closes `alert_fd` only when `!do_fsync()`. |

## Build

```
guest/proton/build.sh WORKDIR [GE-TAG]      # GE-TAG defaults to GE-Proton11-11
```

It runs in a throwaway Debian 13 container (Docker), which:

1. clones `GloriousEggroll/proton-ge-custom` at the tag and fetches its `wine` and
   `wine-staging` submodules at the commits the tag pins (`prepare-wine.sh`);
2. applies GE's Wine patches by running the Wine section of GE's
   `patches/protonprep-valve-staging.sh`;
3. applies this directory's patches and builds only the modules they change (`ntdll.so` and
   `win32u.so`), for x86_64 and i386, into `WORKDIR/out/{x86_64,i386}-unix/`.

`WORKDIR` keeps the sources, so a rebuild with changed patches skips the download. A
GE-Proton11-11 build takes a few minutes on the GPU workstation.

## Install

On the host whose computers use the release (`/opt/caboose-games/GE-Proton11-11` in the
computer, a read-only bind of the release directory), with no game running:

```
for arch in x86_64-unix i386-unix; do
  for mod in ntdll.so win32u.so; do
    cp -a "files/lib/wine/$arch/$mod" "files/lib/wine/$arch/$mod.ge"
    install -m 0555 "WORKDIR/out/$arch/$mod" "files/lib/wine/$arch/"
  done
done
```

A game started afterwards uses them; its prefix needs nothing. Restoring the `.ge` copies
undoes it.

## Check

`check-rotation.sh` (run with Docker on the GPU workstation) starts caboose-display at
1338x911, runs a DPI-aware Wine program with the release's Wine, and turns the display to
932x1356 under it: with GE's `win32u.so` the program ends on the assertion, with the
rebuilt one it keeps running and reports the rotated raw DPI (`67 143`).
