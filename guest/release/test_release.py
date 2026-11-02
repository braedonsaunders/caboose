"""Unit tests for caboose-release's releases: python3 -m unittest guest/release/test_release.py"""
import importlib.machinery
import importlib.util
import os
from pathlib import Path
import tempfile
import unittest

HERE = Path(__file__).resolve().parent
loader = importlib.machinery.SourceFileLoader("caboose_release", str(HERE / "caboose-release"))
spec = importlib.util.spec_from_loader("caboose_release", loader)
release = importlib.util.module_from_spec(spec)
loader.exec_module(release)


class Releases(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        release.ROOT = Path(self.tmp.name) / "releases"
        self.source = Path(self.tmp.name) / "driver.so"
        self.source.write_bytes(b"driver")

    def tearDown(self):
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
        release.verify(directory)
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
        self.assertFalse((directory / "MANIFEST").exists() or (directory / "notes").exists())

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


if __name__ == "__main__":
    unittest.main()
