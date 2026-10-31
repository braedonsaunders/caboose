#!/usr/bin/env python3
"""Stage the supervised broker, and with --driver the phone's Vulkan driver; starts nothing.

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


def install_driver(library: Path, destination: Path):
    data = library.read_bytes()
    if data[:4] != b"\x7fELF":
        raise ValueError(f"{library} is not a shared library")
    directory = destination / DRIVER_DIR
    if directory.is_symlink():
        raise ValueError("driver install directory must not be a symlink")
    directory.mkdir(mode=0o755, parents=True, exist_ok=True)
    # The library first: the manifest never names a library that is not there.
    write_atomically(directory / DRIVER, data, 0o644)
    write_atomically(directory / "icd.json", manifest(Path("/") / DRIVER_DIR / DRIVER), 0o644)


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
    args = parser.parse_args()
    install(args.source_root, args.destdir)
    if args.driver:
        install_driver(args.driver, args.destdir)
