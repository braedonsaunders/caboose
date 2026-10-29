import gzip
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

import repository


class RepositoryTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)

    def package(self, arch="all", name="caboose-test"):
        path = self.root / f"{name}-{arch}.deb"
        path.write_bytes(f"fixture-{name}-{arch}".encode())
        return path

    def metadata(self, command, **kwargs):
        contents = Path(command[-1]).read_text()
        name, arch = contents.removeprefix("fixture-").rsplit("-", 1)
        return subprocess.CompletedProcess(command, 0, stdout=(
            f"Package: {name}\nVersion: 1:2.3-1\nArchitecture: {arch}\n"
            "Description: Example\n A multiline description.\nDepends: python3\n"
            "Filename: ../../wrong\nSize: 0\nSHA256: incorrect\n"))

    def assemble(self, packages, name="repo"):
        root = self.root / name
        root.mkdir()
        with patch.object(repository.subprocess, "run", side_effect=self.metadata):
            repository.assemble(root, packages, ["amd64", "arm64"], "trixie", "main", 1700000000)
        return root

    def test_architecture_selection_and_index_integrity(self):
        common, native = self.package(), self.package("amd64", "caboose-native")
        root = self.assemble([common, native])
        dist = root / "dists/trixie"
        for arch, count in (("amd64", 2), ("arm64", 1)):
            directory = dist / f"main/binary-{arch}"
            data = (directory / "Packages").read_bytes()
            self.assertEqual(data.count(b"Package: "), count)
            self.assertEqual(gzip.decompress((directory / "Packages.gz").read_bytes()), data)
            for block in data.decode().strip().split("\n\n"):
                fields = repository.control_fields(block)
                package = root / fields["filename"]
                self.assertTrue(package.is_relative_to(root / "pool"))
                self.assertEqual(fields["sha256"], repository.digest_file(package, "sha256"))
                self.assertEqual(int(fields["size"]), package.stat().st_size)
                self.assertEqual(fields["description"], "Example\n A multiline description.")
            for index in ("Packages", "Packages.gz"):
                path = directory / index
                for algorithm in ("sha256", "sha512"):
                    digest = repository.digest_file(path, algorithm)
                    by_hash = directory / "by-hash" / algorithm.upper() / digest
                    self.assertEqual(by_hash.read_bytes(), path.read_bytes())
                    self.assertIn(f" {digest} {path.stat().st_size:16} {path.relative_to(dist)}\n",
                                  (dist / "Release").read_text())
        self.assertFalse((dist / "InRelease").exists())
        # Fixed inputs/date produce identical indexes and metadata.
        second = self.assemble([native, common], "second")
        for path in dist.rglob("*"):
            if path.is_file():
                self.assertEqual(path.read_bytes(), (second / path.relative_to(root)).read_bytes())

    def test_reject_duplicate_or_unselected_architecture(self):
        package = self.package()
        with self.assertRaisesRegex(ValueError, "Duplicate"):
            self.assemble([package, package])
        with self.assertRaisesRegex(ValueError, "not selected"):
            self.assemble([self.package("i386")], "wrong-arch")

    def test_reject_ambiguous_and_unsafe_control_fields(self):
        valid = "Package: caboose-test\nVersion: 1.0\nArchitecture: all\nDescription: Example\n"
        for text in (valid + "PACKAGE: duplicate\n", valid.replace("1.0", "../../escape"),
                     valid.replace("all", "amd64\nFilename: evil\nArchitecture: all"),
                     valid.replace("caboose-test", "../../escape")):
            with self.subTest(text=text), self.assertRaises(ValueError):
                repository.control_fields(text)

    def test_cli_refuses_overwrite_and_path_traversal(self):
        output = self.root / "existing"
        output.mkdir()
        marker = output / "keep"
        marker.write_text("original")
        for extra in ([], ["--suite", "../escape"]):
            result = subprocess.run([sys.executable, str(Path(repository.__file__)), "missing.deb",
                                     "--output", str(output), "--timestamp", "1700000000", *extra],
                                    capture_output=True, text=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertEqual(marker.read_text(), "original")

    def test_failed_package_query_leaves_no_output(self):
        output = self.root / "absent"
        with patch.object(sys, "argv", ["repository", str(self.package()), "--output", str(output),
                                       "--timestamp", "1700000000"]):
            with patch.object(repository.subprocess, "run", side_effect=RuntimeError("query failed")):
                with self.assertRaisesRegex(RuntimeError, "query failed"):
                    repository.main()
        self.assertFalse(output.exists())
        self.assertEqual(list(self.root.glob(".caboose-repository-*")), [])

    def test_signing_requires_explicit_key_and_both_signatures(self):
        root = self.root / "signed"
        root.mkdir()
        calls = []

        def run(command, **kwargs):
            if command[0] == "dpkg-deb":
                return self.metadata(command, **kwargs)
            calls.append(command)
            self.assertEqual(command[command.index("--local-user") + 1], "test-fingerprint")
            Path(command[command.index("--output") + 1]).write_text("fixture signature")
            return subprocess.CompletedProcess(command, 0)

        with patch.object(repository.subprocess, "run", side_effect=run):
            repository.assemble(root, [self.package()], ["amd64"], "trixie", "main",
                                1700000000, "test-fingerprint")
        self.assertEqual(len(calls), 2)
        self.assertIn("--clearsign", calls[0])
        self.assertIn("--detach-sign", calls[1])

    def test_failed_signature_leaves_no_output(self):
        output = self.root / "failed-signature"

        def run(command, **kwargs):
            if command[0] == "dpkg-deb":
                return self.metadata(command, **kwargs)
            raise subprocess.CalledProcessError(2, command)

        with patch.object(sys, "argv", ["repository", str(self.package()), "--output", str(output),
                                       "--timestamp", "1700000000", "--signing-key", "missing-key"]):
            with patch.object(repository.subprocess, "run", side_effect=run):
                with self.assertRaises(subprocess.CalledProcessError):
                    repository.main()
        self.assertFalse(output.exists())
        self.assertEqual(list(self.root.glob(".caboose-repository-*")), [])

    @unittest.skipUnless(shutil.which("dpkg-deb"), "requires Debian dpkg-deb")
    def test_real_debian_package(self):
        source = self.root / "package"
        (source / "DEBIAN").mkdir(parents=True)
        (source / "DEBIAN/control").write_text(
            "Package: caboose-test\nVersion: 1.0\nArchitecture: all\nMaintainer: Test <test@example.com>\n"
            "Description: Test package\n A multiline description.\n")
        package = self.root / "real.deb"
        subprocess.run(["dpkg-deb", "--build", str(source), str(package)], check=True, capture_output=True)
        root = self.root / "real"
        root.mkdir()
        repository.assemble(root, [package], ["amd64", "arm64"], "trixie", "main", 1700000000)
        self.assertIn("Package: caboose-test", (root / "dists/trixie/main/binary-arm64/Packages").read_text())


if __name__ == "__main__":
    unittest.main()
