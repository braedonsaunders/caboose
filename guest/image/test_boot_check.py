from pathlib import Path
import tempfile
import unittest

from boot_check import inject


class BootCheckTests(unittest.TestCase):
    def test_plain_and_early_archive_layouts_preserve_original_order(self):
        for layout in (".", "main"):
            with self.subTest(layout=layout), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary) / "unpacked"
                directory = root / layout / "scripts/local-bottom"
                directory.mkdir(parents=True)
                original = '/scripts/local-bottom/caboose-system "$@"\n'
                (directory / "ORDER").write_text(original)
                early = root / "early"
                early.mkdir()
                (early / "keep").write_bytes(b"early archive data")
                extra = Path(temporary) / "extra"
                extra.mkdir()
                for name in ("00-caboose-device-check", "zz-caboose-boot-check"):
                    (extra / name).write_text("#!/bin/sh\nexit 0\n")
                self.assertEqual(inject(root, extra), root / layout)
                commands = (directory / "ORDER").read_text().splitlines()
                self.assertIn("00-caboose-device-check", commands[0])
                self.assertEqual(commands[1], original.strip())
                self.assertIn("zz-caboose-boot-check", commands[-1])
                self.assertEqual((early / "keep").read_bytes(), b"early archive data")
                self.assertEqual((directory / "00-caboose-device-check").stat().st_mode & 0o777, 0o755)

    def test_missing_or_ambiguous_main_archive_is_rejected(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            with self.assertRaises(ValueError):
                inject(root, root)
            for layout in (".", "main"):
                directory = root / layout / "scripts/local-bottom"
                directory.mkdir(parents=True)
                (directory / "ORDER").write_text("")
            with self.assertRaises(ValueError):
                inject(root, root)


if __name__ == "__main__":
    unittest.main()
