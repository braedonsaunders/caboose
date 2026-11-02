#!/usr/bin/env python3
"""Stage the supervised broker and Mesa's driver for the vgem render node, and with --driver the phone's Vulkan driver (with
--executor-switch and --routing-layer its implicit layers); starts nothing.

The driver goes to /usr/local/lib/caboose-gpu-live with its loader manifest, icd.json,
which no loader finds by itself: caboose-display names it to the applications of the
seat that renders on the phone's GPU (docs/gpu-live.md, "Applications"). Each option may
be given twice, with the 64-bit build and with the i386 build for 32-bit applications,
which goes to the i386 directory beside it; a library's architecture is read from it."""
import argparse
import json
import os
from pathlib import Path
import tempfile

MODULES = ("gpu_admission.py", "gpu_websocket.py", "ipc_handoff.py",
           "process_binding.py", "executor_lease.py", "control_protocol.py",
           "surface_local_protocol.py", "buffer_presentation.py")

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
# 32-bit applications on x86-64 see the i386 build as the "host" GL32 extension.
FLATPAK_EXTENSIONS = Path("var/lib/flatpak/extension")
# By a library's architecture: its Flatpak extension, the extension's architecture, the
# sandbox's library triplet, and its directory and name suffix on the computer.
TARGETS = {
    "x86_64": ("org.freedesktop.Platform.GL.host", "x86_64", "x86_64-linux-gnu", "", ""),
    "aarch64": ("org.freedesktop.Platform.GL.host", "aarch64", "aarch64-linux-gnu", "", ""),
    "i386": ("org.freedesktop.Platform.GL32.host", "x86_64", "i386-linux-gnu", "i386", "_32"),
}
ELF_MACHINES = {3: "i386", 62: "x86_64", 183: "aarch64"}
# The broker's sockets for Flatpak applications, as caboose-session places them.
FLATPAK_OVERRIDE = Path("var/lib/flatpak/overrides/global")
SOCKET_FILESYSTEM = "xdg-run/caboose-gpu"
# Mesa's driver for the vgem render node, Zink (docs/gpu-buffers.md), for the computer and
# in each "host" GL extension for Flatpak applications.
DRIRC = "caboose-vgem.conf"
DRIRC_DIR = Path("usr/share/drirc.d")


def drirc_configdir(triplet: str) -> str:
    """DRIRC_CONFIGDIR for Flatpak applications: Mesa reads its configuration from these
    directories in place of its own. The runtime's Mesa defaults and the host extension's
    entry, at their sandbox paths and at Steam's container runtime's (pressure-vessel's),
    where the sandbox's /usr is /run/parent/usr and the defaults keep their path; the
    directories a process does not have are skipped."""
    gl = f"/usr/lib/{triplet}/GL"
    return ":".join((f"{gl}/default/share/drirc.d", f"{gl}/host/share/drirc.d",
                     f"/run/parent{gl}/host/share/drirc.d"))


def flatpak_extension(target: str) -> tuple:
    """The extension's directory and the sandbox's library directory for `target`."""
    extension, arch, triplet, _, _ = TARGETS[target]
    return FLATPAK_EXTENSIONS / extension / arch / "1.4", Path("/usr/lib") / triplet / "GL/host"


def library_target(data: bytes, machine: str) -> str:
    """The architecture a shared library was built for, from its ELF header, or `machine`
    when the header names none."""
    if data[:4] != b"\x7fELF":
        raise ValueError("not a shared library")
    elf_machine = int.from_bytes(data[18:20], "little") if len(data) >= 20 else 0
    target = ELF_MACHINES.get(elf_machine, machine if elf_machine == 0 else None)
    if target not in TARGETS:
        raise ValueError(f"no install target for ELF machine {elf_machine}")
    return target


def driver_dir(target: str) -> Path:
    return DRIVER_DIR / TARGETS[target][3]


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


def with_environment(keyfile: str, name: str, value: str) -> str:
    """A Flatpak override keyfile with `name=value` in its [Environment] group."""
    lines = keyfile.splitlines()
    group = next((i for i, line in enumerate(lines) if line.strip() == "[Environment]"), None)
    if group is None:
        lines += (["[Environment]"] if not lines else ["", "[Environment]"]) + [f"{name}={value}"]
        return "\n".join(lines) + "\n"
    end = next((i for i in range(group + 1, len(lines)) if lines[i].startswith("[")), len(lines))
    for i in range(group + 1, end):
        if lines[i].partition("=")[0].strip() == name:
            lines[i] = f"{name}={value}"
            return "\n".join(lines) + "\n"
    lines.insert(group + 1, f"{name}={value}")
    return "\n".join(lines) + "\n"


def install_drirc(data: bytes, destination: Path, machine: str = os.uname().machine):
    """Installs the vgem driconf entry for the computer's Mesa and for every Flatpak
    application's, in the host GL extensions of this machine's architectures."""
    machine = {"arm64": "aarch64", "amd64": "x86_64"}.get(machine, machine)
    if machine not in ("x86_64", "aarch64"):
        raise ValueError(f"no driconf install target for {machine}")
    targets = [machine] + (["i386"] if machine == "x86_64" else [])
    directories = [destination / DRIRC_DIR] + [destination / flatpak_extension(t)[0] / "share/drirc.d" for t in targets]
    for directory in directories:
        if directory.is_symlink():
            raise ValueError("driconf install directories must not be symlinks")
        directory.mkdir(mode=0o755, parents=True, exist_ok=True)
        write_atomically(directory / DRIRC, data, 0o644)
    override = destination / FLATPAK_OVERRIDE
    override.parent.mkdir(mode=0o755, parents=True, exist_ok=True)
    current = override.read_text() if override.exists() else ""
    updated = with_environment(current, "DRIRC_CONFIGDIR", drirc_configdir(TARGETS[machine][2]))
    if updated != current:
        write_atomically(override, updated.encode(), 0o644)


def install_driver(library: Path, destination: Path, machine: str = os.uname().machine):
    data = library.read_bytes()
    try:
        target = library_target(data, machine)
    except ValueError as error:
        raise ValueError(f"{library}: {error}") from None
    directory = destination / driver_dir(target)
    extension, sandbox = flatpak_extension(target)
    extension = destination / extension
    for d in (destination / DRIVER_DIR, directory, extension):
        if d.is_symlink():
            raise ValueError("driver install directories must not be symlinks")
    directory.mkdir(mode=0o755, parents=True, exist_ok=True)
    # The library first: the manifest never names a library that is not there.
    write_atomically(directory / DRIVER, data, 0o644)
    write_atomically(directory / "icd.json", manifest(Path("/") / driver_dir(target) / DRIVER), 0o644)
    (extension / "lib").mkdir(mode=0o755, parents=True, exist_ok=True)
    (extension / "vulkan/icd.d").mkdir(mode=0o755, parents=True, exist_ok=True)
    write_atomically(extension / "lib" / DRIVER, data, 0o644)
    write_atomically(extension / "vulkan/icd.d/caboose_gfxstream.json", manifest(sandbox / "lib" / DRIVER), 0o644)
    override = destination / FLATPAK_OVERRIDE
    override.parent.mkdir(mode=0o755, parents=True, exist_ok=True)
    current = override.read_text() if override.exists() else ""
    write_atomically(override, with_filesystem(current, SOCKET_FILESYSTEM).encode(), 0o644)


# The implicit layers the seat's launch environment enables, by name: their library, their
# manifest's file name, what they do and their switches. The i386 builds' names and
# manifests carry the suffix _32: the Vulkan loader keeps one layer of a name, also when
# its library is of the other architecture, so each architecture's has its own.
LAYERS = {
    "executor-switch": ("VK_LAYER_CABOOSE_executor_switch", "libVkLayer_caboose_executor_switch.so",
                        "caboose_executor_switch.json",
                        "Loses CPU-implementation devices once a phone GPU executor is available",
                        "CABOOSE_GPU_EXECUTOR_SWITCH"),
    "routing": ("VK_LAYER_CABOOSE_gpu_routing", "libVkLayer_caboose_gpu_routing.so", "caboose_gpu_routing.json",
                "Lists the phone's GPU first and settles the process's device-loss policy",
                "CABOOSE_GPU_ROUTING"),
}
LAYER_MANIFESTS = Path("usr/local/share/vulkan/implicit_layer.d")


def layer_manifest(layer: str, library: Path, suffix: str = "") -> bytes:
    name, _, _, description, switch = LAYERS[layer]
    return (json.dumps({"file_format_version": "1.2.0", "layer": {
        "name": name + suffix,
        "type": "GLOBAL",
        "library_path": str(library),
        "api_version": "1.3.275",
        "implementation_version": "1",
        "description": description,
        "enable_environment": {switch: "1"},
        "disable_environment": {switch + "_DISABLE": "1"},
    }}, indent=4) + "\n").encode()


def install_layer(layer: str, library: Path, destination: Path, machine: str = os.uname().machine):
    """Installs a built layer for the computer and for Flatpak applications."""
    _, file_name, manifest_name, _, _ = LAYERS[layer]
    data = library.read_bytes()
    try:
        target = library_target(data, machine)
    except ValueError as error:
        raise ValueError(f"{library}: {error}") from None
    suffix = TARGETS[target][4]
    manifest_name = manifest_name.removesuffix(".json") + suffix + ".json"
    directory = destination / driver_dir(target)
    manifests = destination / LAYER_MANIFESTS
    extension, sandbox = flatpak_extension(target)
    extension = destination / extension
    for d in (destination / DRIVER_DIR, directory, manifests, extension):
        if d.is_symlink():
            raise ValueError("layer install directories must not be symlinks")
    directory.mkdir(mode=0o755, parents=True, exist_ok=True)
    manifests.mkdir(mode=0o755, parents=True, exist_ok=True)
    write_atomically(directory / file_name, data, 0o644)
    write_atomically(manifests / manifest_name,
                     layer_manifest(layer, Path("/") / driver_dir(target) / file_name, suffix), 0o644)
    (extension / "lib").mkdir(mode=0o755, parents=True, exist_ok=True)
    (extension / "vulkan/implicit_layer.d").mkdir(mode=0o755, parents=True, exist_ok=True)
    write_atomically(extension / "lib" / file_name, data, 0o644)
    write_atomically(extension / "vulkan/implicit_layer.d" / manifest_name,
                     layer_manifest(layer, sandbox / "lib" / file_name, suffix), 0o644)


def install(source: Path, destination: Path, machine: str = os.uname().machine):
    libexec = destination / "usr/local/libexec"
    private = libexec / "caboose-gpu"
    files = [(source / "gfxstream" / name, private / name, 0o644) for name in MODULES]
    files += [(source / "broker/live_surface_protocol.py", private / "live_surface_protocol.py", 0o644),
              (source / "broker/live_compression.py", private / "live_compression.py", 0o644),
              (source / "broker/live_zstd.py", private / "live_zstd.py", 0o644),
              (source / "broker/live_protocol.py", private / "live_protocol.py", 0o644),
              (source / "gfxstream/caboose-gpu-broker", private / "broker.py", 0o644),
              (source / "caboose-gpu-broker-launcher", libexec / "caboose-gpu-broker", 0o755)]
    # Fail before modifying the install when a component was omitted from a bundle.
    contents = [(src.read_bytes(), dst, mode) for src, dst, mode in files]
    drirc = (source / DRIRC).read_bytes()
    if private.is_symlink() or libexec.is_symlink():
        raise ValueError("broker install directories must not be symlinks")
    private.mkdir(mode=0o755, parents=True, exist_ok=True)
    for data, destination_file, mode in contents:
        write_atomically(destination_file, data, mode)
    install_drirc(drirc, destination, machine)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source-root", type=Path, default=Path(__file__).resolve().parent)
    parser.add_argument("--destdir", type=Path, default=Path("/"))
    parser.add_argument("--driver", type=Path, action="append", default=[],
                        help="a built libvulkan_gfxstream.so to install")
    parser.add_argument("--executor-switch", type=Path, action="append", default=[],
                        help="a built libVkLayer_caboose_executor_switch.so to install as an implicit layer")
    parser.add_argument("--routing-layer", type=Path, action="append", default=[],
                        help="a built libVkLayer_caboose_gpu_routing.so to install as an implicit layer")
    args = parser.parse_args()
    install(args.source_root, args.destdir)
    for driver in args.driver:
        install_driver(driver, args.destdir)
    for layer in args.executor_switch:
        install_layer("executor-switch", layer, args.destdir)
    for layer in args.routing_layer:
        install_layer("routing", layer, args.destdir)
