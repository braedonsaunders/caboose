#!/usr/bin/env python3
"""Stage the supervised broker; does not start it or install/enable an ICD."""
import argparse
import os
from pathlib import Path
import tempfile

MODULES = ("gpu_admission.py", "gpu_websocket.py", "ipc_handoff.py",
           "process_binding.py", "executor_lease.py", "control_protocol.py")


def install(source: Path, destination: Path):
    libexec = destination / "usr/local/libexec"
    private = libexec / "caboose-gpu"
    files = [(source / "gfxstream" / name, private / name, 0o644) for name in MODULES]
    files += [(source / "broker/live_protocol.py", private / "live_protocol.py", 0o644),
              (source / "gfxstream/caboose-gpu-broker", private / "broker.py", 0o644),
              (source / "caboose-gpu-broker-launcher", libexec / "caboose-gpu-broker", 0o755)]
    # Fail before modifying the install when a component was omitted from a bundle.
    contents = [(src.read_bytes(), dst, mode) for src, dst, mode in files]
    if private.is_symlink() or libexec.is_symlink():
        raise ValueError("broker install directories must not be symlinks")
    private.mkdir(mode=0o755, parents=True, exist_ok=True)
    for data, destination_file, mode in contents:
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


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source-root", type=Path, default=Path(__file__).resolve().parent)
    parser.add_argument("--destdir", type=Path, default=Path("/"))
    args = parser.parse_args()
    install(args.source_root, args.destdir)
