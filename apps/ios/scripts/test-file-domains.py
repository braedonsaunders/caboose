#!/usr/bin/env python3
"""Exercise production registration ordering with delayed, failing system callbacks."""
import pathlib
import subprocess
import tempfile

root = pathlib.Path(__file__).resolve().parents[1]
with tempfile.TemporaryDirectory(prefix="caboose-file-domains-") as directory:
    directory = pathlib.Path(directory)
    # Substitute only the OS API boundary; execute the unchanged production lifecycle.
    source = (root / "Caboose/FileDomains.swift").read_text().replace("import FileProvider\n", "")
    (directory / "FileDomains.swift").write_text(source)
    subprocess.run(["xcrun", "swiftc", "-parse-as-library", str(directory / "FileDomains.swift"),
                    str(root / "scripts/test-file-domains.swift"), "-o", str(directory / "test")], check=True)
    subprocess.run([str(directory / "test")], check=True)
