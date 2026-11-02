"""Unit tests for caboose-release's releases: python3 -m unittest guest/release/test_release.py"""
import importlib.machinery
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

HERE = Path(__file__).resolve().parent
loader = importlib.machinery.SourceFileLoader("caboose_release", str(HERE / "caboose-release"))
spec = importlib.util.spec_from_loader("caboose_release", loader)
release = importlib.util.module_from_spec(spec)
loader.exec_module(release)


def keypair(directory, name):
    """A throwaway Ed25519 key and its public key, as the release key would be."""
    key, public = Path(directory) / f"{name}.key.pem", Path(directory) / f"{name}.pub.pem"
    subprocess.run(["openssl", "genpkey", "-algorithm", "ed25519", "-out", str(key)], check=True, capture_output=True)
    subprocess.run(["openssl", "pkey", "-in", str(key), "-pubout", "-out", str(public)], check=True, capture_output=True)
    return key, public


class Releases(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        release.ROOT = Path(self.tmp.name) / "releases"
        self.source = Path(self.tmp.name) / "driver.so"
        self.source.write_bytes(b"driver")
        release.KEY, public = keypair(self.tmp.name, "release")
        os.environ["CABOOSE_RELEASE_PUB"] = str(public)

    def tearDown(self):
        os.environ.pop("CABOOSE_RELEASE_PUB", None)
        self.tmp.cleanup()

    def test_a_sealed_release_lists_every_file_and_detects_changes(self):
        release.main(["new", "r1"])
        release.main(["add", "r1", str(self.source), "/usr/local/lib/caboose-gpu-live/libvulkan_gfxstream.so", "755"])
        release.main(["remove", "r1", "/etc/chromium.d/caboose-scroll"])
        release.main(["seal", "r1", "driver=cbV33", "display=66554e57"])
        directory = release.ROOT / "r1"
        manifest = (directory / "MANIFEST").read_text()
        self.assertIn("0755  files/usr/local/lib/caboose-gpu-live/libvulkan_gfxstream.so", manifest)
        self.assertIn("notes", manifest)
        self.assertIn("remove", manifest)
        self.assertIn("sbom.spdx.json", manifest)
        self.assertNotIn("MANIFEST", manifest)
        release.verify(directory)
        release.verify_signature(directory)
        (directory / "files/usr/local/lib/caboose-gpu-live/libvulkan_gfxstream.so").write_bytes(b"other")
        with self.assertRaises(release.Failure):
            release.verify(directory)

    def test_a_sealed_release_is_final_and_a_new_one_starts_from_it(self):
        release.main(["new", "r1"])
        release.main(["add", "r1", str(self.source), "/usr/local/bin/x"])
        release.main(["seal", "r1", "first"])
        with self.assertRaises(release.Failure):
            release.main(["add", "r1", str(self.source), "/usr/local/bin/y"])
        release.main(["new", "r2", "--from", "r1"])
        directory = release.ROOT / "r2"
        self.assertTrue((directory / "files/usr/local/bin/x").is_file())
        for name in ("MANIFEST", "MANIFEST.sig", "notes", "sbom.spdx.json"):
            self.assertFalse((directory / name).exists(), name)

    def test_paths_must_be_absolute_and_ids_plain(self):
        release.main(["new", "r1"])
        for path in ("relative/x", "/usr/../etc/x"):
            with self.assertRaises(release.Failure):
                release.main(["add", "r1", str(self.source), path])
        for id_ in ("../x", ".hidden", ""):
            with self.assertRaises(release.Failure):
                release.release(id_)

    def test_the_marker_names_the_release_its_manifest_and_notes(self):
        release.main(["new", "r4.2"])
        release.main(["add", "r4.2", str(self.source), "/usr/local/bin/x"])
        release.main(["seal", "r4.2", "driver=cbV33 (main 745bcc85)"])
        text = release.marker_text(release.ROOT / "r4.2")
        lines = text.splitlines()
        self.assertEqual(lines[0], "r4.2")
        self.assertTrue(lines[1].startswith("manifest_sha256=") and len(lines[1]) == len("manifest_sha256=") + 64)
        self.assertEqual(lines[2], "driver=cbV33 (main 745bcc85)")

    def test_a_release_is_signed_and_only_the_release_key_verifies_it(self):
        release.main(["new", "r1"])
        release.main(["add", "r1", str(self.source), "/usr/local/bin/x"])
        release.main(["seal", "r1", "first"])
        directory = release.ROOT / "r1"
        release.verify_signature(directory)
        # A changed MANIFEST, a signature by another key, or none at all are refused.
        manifest = (directory / "MANIFEST").read_bytes()
        (directory / "MANIFEST").write_bytes(manifest.replace(b"0644", b"0755"))
        with self.assertRaises(release.Failure):
            release.verify_signature(directory)
        (directory / "MANIFEST").write_bytes(manifest)
        other, _ = keypair(self.tmp.name, "other")
        signature = (directory / "MANIFEST.sig").read_text()
        with self.assertRaises(release.Failure):
            release.sign(directory, other)
        self.assertEqual((directory / "MANIFEST.sig").read_text(), signature, "a signature that does not verify is not kept")
        (directory / "MANIFEST.sig").unlink()
        with self.assertRaises(release.Failure):
            release.verify_signature(directory)
        release.main(["sign", "r1"])
        release.verify_signature(directory)

    def test_sealing_needs_the_signing_key(self):
        release.main(["new", "r1"])
        release.KEY = Path(self.tmp.name) / "missing.pem"
        with self.assertRaises(release.Failure):
            release.main(["seal", "r1", "first"])
        self.assertFalse(release.sealed(release.ROOT / "r1"))

    def test_the_sbom_lists_every_file_and_package(self):
        release.main(["new", "r1"])
        release.main(["add", "r1", str(self.source), "/usr/local/lib/caboose-gpu-live/libvulkan_gfxstream.so", "755"])
        debs = release.ROOT / "r1" / "debs"
        debs.mkdir()
        (debs / "xwayland_24.1.6-1+caboose1_amd64.deb").write_bytes(b"deb")
        (release.ROOT / "r1" / "notes").write_text("driver=cbV34\n")
        text = release.sbom(release.ROOT / "r1", created="2026-11-02T00:00:00Z",
                            fields=lambda deb: ("xwayland", "2:24.1.6-1+caboose1", "amd64"))
        document = json.loads(text)
        self.assertEqual(document["spdxVersion"], "SPDX-2.3")
        self.assertEqual(document["packages"][0]["versionInfo"], "r1")
        self.assertEqual(document["packages"][0]["comment"], "driver=cbV34")
        (file,) = document["files"]
        self.assertEqual(file["fileName"], "./usr/local/lib/caboose-gpu-live/libvulkan_gfxstream.so")
        self.assertIn({"algorithm": "SHA256", "checksumValue": hashlib.sha256(b"driver").hexdigest()}, file["checksums"])
        deb = document["packages"][1]
        self.assertEqual((deb["name"], deb["versionInfo"]), ("xwayland", "2:24.1.6-1+caboose1"))
        self.assertEqual(deb["externalRefs"][0]["referenceLocator"], "pkg:deb/xwayland@2:24.1.6-1+caboose1?arch=amd64")
        contained = {r["relatedSpdxElement"] for r in document["relationships"] if r["relationshipType"] == "CONTAINS"}
        self.assertEqual(contained, {file["SPDXID"], deb["SPDXID"]})


if __name__ == "__main__":
    unittest.main()
