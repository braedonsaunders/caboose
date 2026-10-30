# Native vkQuake preparation

This directory builds unmodified Linux amd64 vkQuake 1.37.0 at
`749b4fd43fe8b8554b34163dc9469c4a08a4def1` with standalone LibreQuake Lite
v0.09-beta (`d1515ca9bc01e590f2d54dc496f55c9a4ed72369`). The launcher selects
SDL2's native Wayland backend. This is a preparation fixture, not a shipped
Caboose game or evidence of iPhone GPU execution.

## Inputs and licenses

[inputs.json](inputs.json) pins every upstream archive URL, compressed size,
SHA-256 and extracted-size ceiling. [data-files.json](data-files.json) hashes
every released data file, including all bundled notices and credits.

- [vkQuake](https://github.com/Novum/vkQuake): GPL-2.0-or-later; embedded mimalloc
  has its own MIT notice. The source archive and both notices are retained.
- [LibreQuake release](https://github.com/lavenderdotpet/LibreQuake/releases/tag/v0.09-beta):
  the standalone Lite archive contains `id1/pak0.pak`, `pak1.pak`, music, and
  `id1/docs`. Models/textures/sounds are BSD-3-Clause; QuakeC/progs.dat/pop.lmp
  have GPL notices. Preserve the entire docs directory. The complete pinned
  LibreQuake source archive accompanies the release data; this does not use
  proprietary Quake data. See its `docs/README-IMPORTANT-LICENCE-INFO`.
- Official Vulkan-Headers SDK 1.4.341.0, commit
  `b5c8f996196ba4aa6d8f97e52b5d3b6e70f7e4e2`, supplies headers only. Its
  `VK_KHR_present_wait2` declarations are required by this upstream source.
  Header availability does not establish runtime extension support.

## Build and reproduce

Run only on a coordinated Linux amd64 build host. No Mac compilation is needed.
The immutable compiler image is
`sha256:b94dd0452b1d2164d52115722c333cbb51f903e736fa7e7e782d21c52cf40442`
(Debian 13.7, GCC 14.2, Vulkan loader 1.4.309).

1. Copy this directory's scripts and JSON files into a new private task directory.
   Run `python3 prepare.py /absolute/task` to fetch/validate/extract upstream
   inputs. It refuses existing extraction destinations. Alternatively retain the
   verified archives only; `build.sh` extracts missing destinations.
2. Run `python3 fetch-deps.py /absolute/task/debs`. This replays the reviewed
   [dependencies.json](dependencies.json), without resolving new versions.
   Its 82 Debian packages total 29,299,544 compressed bytes. The filenames include
   exact versions; hashes came from APT-verified Debian trixie repository metadata.
3. Extract in the existing Debian helper image
   `sha256:2a13af61e11f259c4aeb19d49303cd02873f8e4d26420cd7fac68ed816233d67`:

   ```sh
   docker run --rm --network none --cpus 2 --memory 3g --pids-limit 128 \
     --mount type=bind,src=/absolute/task,dst=/task \
     --entrypoint timeout \
     sha256:2a13af61e11f259c4aeb19d49303cd02873f8e4d26420cd7fac68ed816233d67 \
     60 python3 /task/extract-debs.py
   ```

   This validates all hashes and paths before extraction (136,185,243 bytes),
   confines links to the private sysroot, and runs no package maintainer scripts.
   `acquire-deps.sh` records the initial signed-metadata resolution; it is an audit
   helper, **not** the pinned reproduction entry point. Its original lists/status
   and download log are retained with the build artifacts.
4. Run `./run-build.sh /absolute/task`. It uses two jobs, two CPUs, 3 GiB,
   a 300-second timeout, no network, and only the task mount. It removes its exact
   container on exit. `SOURCE_DATE_EPOCH=1793318400`, locale, timezone and the
   container build path are fixed. Upstream release optimizations and music codecs
   remain enabled. No graphics source or device capabilities are changed.

`bundle/` contains the executable, data, launcher, notices, input lock, and a
per-file SHA-256 manifest. `package.py` verifies every original upstream source
file remains byte-identical. For a clean repeat, use a new task directory with
identical inputs/dependencies. `python3 test_prepare.py` checks archive path,
link, duplicate and size rejection plus regular-file extraction.

## Runtime dependencies and launch

The ELF needs `libSDL2-2.0.so.0`, `libvulkan.so.1`, `libvorbisfile.so.3`,
`libmpg123.so.0`, glibc and libm, plus their transitive dependencies. The pinned
compiler image plus the private dependency sysroot resolves the full closure;
`ldd.txt` records it. The executable has no RPATH/RUNPATH. The bundle does not
claim to be a portable static binary, and does not include a Vulkan driver.
A Debian 13-compatible runtime with SDL2 Wayland support is required.

```sh
export CABOOSE_GAME_BUNDLE=/absolute/task/bundle
# Needed when using the private dependency sysroot instead of installed runtime libs:
export CABOOSE_GAME_LIBRARY_DIR=/absolute/task/deps/usr/lib/x86_64-linux-gnu
export XDG_RUNTIME_DIR=/path/to/private/runtime
export WAYLAND_DISPLAY=wayland-game-check
/absolute/task/bundle/launch.sh +map start
```

The caller must provide an actual Wayland compositor and Vulkan WSI-capable
ICD. The launcher does not fall back to X11, select a fake ICD, modify memory
properties, or install anything. Keep writable game data/config in the private
fixture directory. Live phone presentation, shader/feature compatibility, and
host-visible memory synchronization are separate integration checks.
