import re
import sys
import tempfile
from pathlib import Path
import unittest

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE / 'driver'))
import prepare  # noqa: E402


class DriverSeriesTest(unittest.TestCase):
    def test_series_is_numbered_without_gaps(self):
        series = prepare.patches()
        self.assertGreater(len(series), 0)
        self.assertEqual([p.name[:4] for p in series],
                         [f'{i:04d}' for i in range(1, len(series) + 1)])

    def test_patches_change_only_upstream_gfxstream_files(self):
        owned = set(prepare.OWNED.values())
        for patch in prepare.patches():
            paths = prepare.patched_paths(patch)
            self.assertTrue(paths, patch.name)
            for path in paths:
                self.assertTrue(path.startswith('src/gfxstream/'), (patch.name, path))
                self.assertNotIn(path, owned, patch.name)

    def test_patches_describe_their_change(self):
        for patch in prepare.patches():
            text = patch.read_text()
            subject = re.search(r'^Subject: \[PATCH \d+/\d+\] (.+)$', text, re.M)
            self.assertIsNotNone(subject, patch.name)
            body = text.split('\n\n', 1)[1].split('\n---\n', 1)[0]
            self.assertGreater(len(body.strip()), 80, patch.name)

    def test_owned_sources_exist(self):
        for source, destination in prepare.OWNED.items():
            self.assertTrue((prepare.GFXSTREAM / source).is_file(), source)
            self.assertTrue(destination.startswith('src/gfxstream/guest/'), destination)

    def test_fetch_and_prepare_pin_the_same_revision(self):
        fetch = (HERE / 'fetch_mesa.sh').read_text()
        self.assertIn(f'revision={prepare.MESA_REVISION}\n', fetch)

    def test_manifest_hashes_every_input(self):
        inputs = prepare.manifest()['inputs']
        self.assertEqual(len(inputs), len(prepare.patches()) + len(prepare.OWNED))
        self.assertTrue(all(re.fullmatch('[0-9a-f]{64}', h) for h in inputs.values()))

    def test_patched_paths_rejects_renames(self):
        with tempfile.TemporaryDirectory() as directory:
            patch = Path(directory) / '0001-rename.patch'
            patch.write_text('diff --git a/src/a.c b/src/b.c\n')
            with self.assertRaises(ValueError):
                prepare.patched_paths(patch)


if __name__ == '__main__':
    unittest.main()
