#!/usr/bin/env python3
"""Assemble a new, static APT repository from existing Debian binary packages."""

import argparse
from datetime import datetime, timezone
from email.utils import format_datetime
import gzip
import hashlib
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile


def control_fields(text):
    """Keep multiline Debian control fields, refusing ambiguous records."""
    fields = {}
    current = None
    for line in text.splitlines():
        if line.startswith((" ", "\t")) and current:
            fields[current] += "\n" + line
            continue
        if not line or ":" not in line:
            raise ValueError("Invalid binary package control record")
        name, value = line.split(":", 1)
        if not re.fullmatch(r"[A-Za-z0-9][-A-Za-z0-9]*", name):
            raise ValueError("Invalid control field name")
        key = name.lower()
        if key in fields:
            raise ValueError(f"Duplicate control field: {name}")
        fields[key] = value.strip()
        current = key
    for name in ("package", "version", "architecture", "description"):
        if not fields.get(name):
            raise ValueError(f"Missing package field: {name}")
    if not re.fullmatch(r"[a-z0-9][a-z0-9+.-]+", fields["package"]):
        raise ValueError("Invalid Debian package name")
    if not re.fullmatch(r"[0-9][A-Za-z0-9.+:~\-]*", fields["version"]):
        raise ValueError("Invalid Debian version")
    if not re.fullmatch(r"[a-z0-9][a-z0-9-]*", fields["architecture"]):
        raise ValueError("Invalid Debian architecture")
    return fields


def digest_file(path, algorithm):
    digest = hashlib.new(algorithm)
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def stanza(fields, path, root):
    # Index-owned fields must describe the bytes we copied, never input metadata.
    ignored = {"filename", "size", "md5sum", "sha1", "sha256", "sha512"}
    lines = [f"{key.title()}: {value}" for key, value in fields.items() if key not in ignored]
    lines += [f"Filename: {path.relative_to(root).as_posix()}", f"Size: {path.stat().st_size}"]
    for field, algorithm in (("MD5sum", "md5"), ("SHA256", "sha256"), ("SHA512", "sha512")):
        lines.append(f"{field}: {digest_file(path, algorithm)}")
    return "\n".join(lines) + "\n\n"


def assemble(root, packages, architectures, suite, component, timestamp, signing_key=None):
    entries = {arch: [] for arch in architectures}
    seen = set()
    for source in sorted(packages):
        # Copy first: control metadata and checksums refer to the same private snapshot.
        with tempfile.TemporaryDirectory(dir=root) as scratch:
            snapshot = Path(scratch) / "package.deb"
            shutil.copyfile(source, snapshot)
            result = subprocess.run(["dpkg-deb", "--field", str(snapshot)], check=True,
                                    capture_output=True, text=True, timeout=60)
            fields = control_fields(result.stdout)
            name, version, arch = (fields[key] for key in ("package", "version", "architecture"))
            if arch != "all" and arch not in entries:
                raise ValueError(f"Package architecture is not selected: {arch}")
            identity = (name, version, arch)
            if identity in seen:
                raise ValueError(f"Duplicate package/version/architecture: {identity}")
            seen.add(identity)
            digest = digest_file(snapshot, "sha256")
            destination = root / "pool" / component / name / f"{digest}.deb"
            destination.parent.mkdir(parents=True, exist_ok=True)
            snapshot.rename(destination)
            record = stanza(fields, destination, root)
            for selected in entries:
                if arch in (selected, "all"):
                    entries[selected].append((identity, record))

    distribution = root / "dists" / suite
    indexes = []
    for arch, records in entries.items():
        directory = distribution / component / f"binary-{arch}"
        directory.mkdir(parents=True)
        content = "".join(record for _, record in sorted(records)).encode()
        for name, data in (("Packages", content), ("Packages.gz", gzip.compress(content, mtime=0))):
            path = directory / name
            path.write_bytes(data)
            indexes.append(path)
            # APT may choose either strong hash advertised by Release.
            for algorithm in ("sha256", "sha512"):
                by_hash = directory / "by-hash" / algorithm.upper() / hashlib.new(algorithm, data).hexdigest()
                by_hash.parent.mkdir(parents=True, exist_ok=True)
                by_hash.write_bytes(data)

    release = ["Origin: Caboose", "Label: Caboose", f"Suite: {suite}", f"Codename: {suite}",
               f"Date: {format_datetime(datetime.fromtimestamp(timestamp, timezone.utc), usegmt=True)}",
               f"Architectures: {' '.join(architectures)}", f"Components: {component}",
               "Acquire-By-Hash: yes"]
    for field, algorithm in (("MD5Sum", "md5"), ("SHA256", "sha256"), ("SHA512", "sha512")):
        release.append(f"{field}:")
        for path in sorted(indexes):
            release.append(f" {digest_file(path, algorithm)} {path.stat().st_size:16} "
                           f"{path.relative_to(distribution).as_posix()}")
    release_path = distribution / "Release"
    release_path.write_text("\n".join(release) + "\n")
    if signing_key:
        common = ["gpg", "--batch", "--no-tty", "--local-user", signing_key, "--digest-algo", "SHA256"]
        for name, operation in (("InRelease", "--clearsign"), ("Release.gpg", "--detach-sign")):
            subprocess.run(common + ["--armor", "--output", str(distribution / name),
                                      operation, str(release_path)], check=True, timeout=120)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("packages", nargs="+", type=Path)
    parser.add_argument("--output", required=True, type=Path, help="New directory; must not exist")
    parser.add_argument("--suite", default="trixie")
    parser.add_argument("--component", default="main")
    parser.add_argument("--architectures", nargs="+", default=["amd64", "arm64"])
    parser.add_argument("--signing-key", help="Existing GPG key fingerprint; never selects a default key")
    parser.add_argument("--timestamp", type=int, default=int(os.environ.get("SOURCE_DATE_EPOCH", "0")),
                        help="Release date as Unix seconds (required unless SOURCE_DATE_EPOCH is set)")
    args = parser.parse_args()
    for value in (args.suite, args.component, *args.architectures):
        if not re.fullmatch(r"[a-z0-9][a-z0-9-]*", value):
            parser.error(f"Invalid repository path component: {value!r}")
    if len(set(args.architectures)) != len(args.architectures) or "all" in args.architectures:
        parser.error("Select distinct concrete architectures; all packages are indexed automatically")
    if args.timestamp <= 0:
        parser.error("Supply --timestamp or SOURCE_DATE_EPOCH")
    output = args.output.absolute()
    if output.exists() or output.is_symlink():
        parser.error("Output already exists; assemble each release into a new directory")
    output.parent.mkdir(parents=True, exist_ok=True)
    # A failed package query/signature never exposes a partial repository.
    with tempfile.TemporaryDirectory(prefix=".caboose-repository-", dir=output.parent) as temporary:
        stage = Path(temporary) / "repository"
        stage.mkdir()
        assemble(stage, args.packages, args.architectures, args.suite, args.component,
                 args.timestamp, args.signing_key)
        stage.rename(output)
    print(output)


if __name__ == "__main__":
    main()
