#!/usr/bin/env python3
"""Stage the supervised broker, and with --driver the phone's Vulkan driver (with
--executor-switch its implicit layer); starts nothing.

The driver goes to /usr/local/lib/caboose-gpu-live with its loader manifest, icd.json,
which no loader finds by itself: caboose-display names it to the applications of the
seat that renders on the phone's GPU (docs/gpu-live.md, "Applications")."""
import argparse
import json
import os
from pathlib import Path
import tempfile

MODULES = ("gpu_admission.py", "gpu_websocket.py", "ipc_handoff.py",
           "process_binding.py", "executor_lease.py", "control_protocol.py",
           "surface_local_protocol.py")

DRIVER_DIR = Path("usr/local/lib/caboose-gpu-live")
DRIVER = "libvulkan_gfxstream.so"
# The Vulkan version the driver reports to the loader; the phone's device reports its own.
DRIVER_API_VERSION = "1.3.0"


def write_atomically(destination_file: Path, data: bytes, mode: int):
    fd, temporary = tempfile.mkstemp(prefix=".gpu-install-", dir=destination_file.parent)
    try:
        with os.fdopen(fd, "wb") as output:
            output.write(data)
            output.flush()
            os.fchmod(output.fileno(), mode)
        os.replace(temporary, destination_file)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def manifest(library: Path) -> bytes:
    return (json.dumps({"file_format_version": "1.0.1",
                        "ICD": {"library_path": str(library), "api_version": DRIVER_API_VERSION}},
                       indent=4) + "\n").encode()


# Flatpak applications see the driver as the "host" GL extension, which Flatpak enables for
# every runtime whose GL extension point accepts version 1.4 (the Freedesktop runtimes
# and those built on them), without a download: an unmaintained extension directory. The
# extension's files appear at /usr/lib/<triplet>/GL/host in the sandbox.
FLATPAK_EXTENSION = Path("var/lib/flatpak/extension/org.freedesktop.Platform.GL.host")
FLATPAK_ARCHES = {"x86_64": ("x86_64", "x86_64-linux-gnu"), "aarch64": ("aarch64", "aarch64-linux-gnu")}
# The broker's sockets for Flatpak applications, as caboose-session places them.
FLATPAK_OVERRIDE = Path("var/lib/flatpak/overrides/global")
SOCKET_FILESYSTEM = "xdg-run/caboose-gpu"


def flatpak_extension(machine: str) -> tuple:
    """The extension's directory and the sandbox's library directory for `machine`."""
    arch, triplet = FLATPAK_ARCHES[machine]
    return FLATPAK_EXTENSION / arch / "1.4", Path("/usr/lib") / triplet / "GL/host"


def with_filesystem(keyfile: str, entry: str) -> str:
    """A Flatpak override keyfile with `entry` among its [Context] filesystems."""
    lines = keyfile.splitlines()
    group = next((i for i, line in enumerate(lines) if line.strip() == "[Context]"), None)
    if group is None:
        lines += (["[Context]", f"filesystems={entry};"] if not lines else ["", "[Context]", f"filesystems={entry};"])
        return "\n".join(lines) + "\n"
    end = next((i for i in range(group + 1, len(lines)) if lines[i].startswith("[")), len(lines))
    for i in range(group + 1, end):
        key, _, value = lines[i].partition("=")
        if key.strip() == "filesystems":
            entries = [e for e in value.strip().split(";") if e]
            if entry not in entries:
                entries.append(entry)
            lines[i] = "filesystems=" + "".join(e + ";" for e in entries)
            return "\n".join(lines) + "\n"
    lines.insert(group + 1, f"filesystems={entry};")
    return "\n".join(lines) + "\n"


def install_driver(library: Path, destination: Path, machine: str = os.uname().machine):
    data = library.read_bytes()
    if data[:4] != b"\x7fELF":
        raise ValueError(f"{library} is not a shared library")
    directory = destination / DRIVER_DIR
    extension, sandbox = flatpak_extension(machine)
    extension = destination / extension
    for d in (directory, extension):
        if d.is_symlink():
            raise ValueError("driver install directories must not be symlinks")
    directory.mkdir(mode=0o755, parents=True, exist_ok=True)
    # The library first: the manifest never names a library that is not there.
    write_atomically(directory / DRIVER, data, 0o644)
    write_atomically(directory / "icd.json", manifest(Path("/") / DRIVER_DIR / DRIVER), 0o644)
    (extension / "lib").mkdir(mode=0o755, parents=True, exist_ok=True)
    (extension / "vulkan/icd.d").mkdir(mode=0o755, parents=True, exist_ok=True)
    write_atomically(extension / "lib" / DRIVER, data, 0o644)
    write_atomically(extension / "vulkan/icd.d/caboose_gfxstream.json", manifest(sandbox / "lib" / DRIVER), 0o644)
    override = destination / FLATPAK_OVERRIDE
    override.parent.mkdir(mode=0o755, parents=True, exist_ok=True)
    current = override.read_text() if override.exists() else ""
    write_atomically(override, with_filesystem(current, SOCKET_FILESYSTEM).encode(), 0o644)


SWITCH_LAYER = "libVkLayer_caboose_executor_switch.so"
SWITCH_MANIFEST = Path("usr/local/share/vulkan/implicit_layer.d/caboose_executor_switch.json")


def switch_manifest(library: Path) -> bytes:
    """The implicit layer that moves CPU devices back to the phone (guest/gpu/executor-switch)."""
    return (json.dumps({"file_format_version": "1.2.0", "layer": {
        "name": "VK_LAYER_CABOOSE_executor_switch",
        "type": "GLOBAL",
        "library_path": str(library),
        "api_version": "1.3.275",
        "implementation_version": "1",
        "description": "Loses CPU-implementation devices once a phone GPU executor is available",
        "enable_environment": {"CABOOSE_GPU_EXECUTOR_SWITCH": "1"},
        "disable_environment": {"CABOOSE_GPU_EXECUTOR_SWITCH_DISABLE": "1"},
    }}, indent=4) + "\n").encode()


def install_switch_layer(library: Path, destination: Path, machine: str = os.uname().machine):
    data = library.read_bytes()
    if data[:4] != b"\x7fELF":
        raise ValueError(f"{library} is not a shared library")
    directory = destination / DRIVER_DIR
    manifests = destination / SWITCH_MANIFEST.parent
    extension, sandbox = flatpak_extension(machine)
    extension = destination / extension
    for d in (directory, manifests, extension):
        if d.is_symlink():
            raise ValueError("layer install directories must not be symlinks")
    directory.mkdir(mode=0o755, parents=True, exist_ok=True)
    manifests.mkdir(mode=0o755, parents=True, exist_ok=True)
    write_atomically(directory / SWITCH_LAYER, data, 0o644)
    write_atomically(destination / SWITCH_MANIFEST, switch_manifest(Path("/") / DRIVER_DIR / SWITCH_LAYER), 0o644)
    (extension / "lib").mkdir(mode=0o755, parents=True, exist_ok=True)
    (extension / "vulkan/implicit_layer.d").mkdir(mode=0o755, parents=True, exist_ok=True)
    write_atomically(extension / "lib" / SWITCH_LAYER, data, 0o644)
    write_atomically(extension / "vulkan/implicit_layer.d" / SWITCH_MANIFEST.name,
                     switch_manifest(sandbox / "lib" / SWITCH_LAYER), 0o644)


def install(source: Path, destination: Path):
    libexec = destination / "usr/local/libexec"
    private = libexec / "caboose-gpu"
    files = [(source / "gfxstream" / name, private / name, 0o644) for name in MODULES]
    files += [(source / "broker/live_surface_protocol.py", private / "live_surface_protocol.py", 0o644),
              (source / "broker/live_compression.py", private / "live_compression.py", 0o644),
              (source / "broker/live_protocol.py", private / "live_protocol.py", 0o644),
              (source / "gfxstream/caboose-gpu-broker", private / "broker.py", 0o644),
              (source / "caboose-gpu-broker-launcher", libexec / "caboose-gpu-broker", 0o755)]
    # Fail before modifying the install when a component was omitted from a bundle.
    contents = [(src.read_bytes(), dst, mode) for src, dst, mode in files]
    if private.is_symlink() or libexec.is_symlink():
        raise ValueError("broker install directories must not be symlinks")
    private.mkdir(mode=0o755, parents=True, exist_ok=True)
    for data, destination_file, mode in contents:
        write_atomically(destination_file, data, mode)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source-root", type=Path, default=Path(__file__).resolve().parent)
    parser.add_argument("--destdir", type=Path, default=Path("/"))
    parser.add_argument("--driver", type=Path, help="a built libvulkan_gfxstream.so to install")
    parser.add_argument("--executor-switch", type=Path,
                        help="a built libVkLayer_caboose_executor_switch.so to install as an implicit layer")
    args = parser.parse_args()
    install(args.source_root, args.destdir)
    if args.driver:
        install_driver(args.driver, args.destdir)
    if args.executor_switch:
        install_switch_layer(args.executor_switch, args.destdir)
