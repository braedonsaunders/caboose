#!/usr/bin/env python3
"""Run pure production collection tests; no Keychain reads/writes or host access."""
import pathlib
import subprocess
import tempfile

root = pathlib.Path(__file__).resolve().parents[1]
with tempfile.TemporaryDirectory(prefix="caboose-computers-") as directory:
    binary = pathlib.Path(directory) / "test"
    subprocess.run(["xcrun", "swiftc", "-parse-as-library",
                    str(root / "Caboose/Host/Credentials.swift"),
                    str(root / "scripts/test-computer-switcher.swift"), "-o", str(binary)], check=True)
    subprocess.run([str(binary)], check=True)
