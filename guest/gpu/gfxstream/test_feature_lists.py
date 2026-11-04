"""Every list of GPU feature names agrees with gpu-features.json (gpu_features.py)."""
import shutil
import tempfile
import unittest
from pathlib import Path

import gpu_features

REPO = Path(__file__).resolve().parents[3]
FILES = (gpu_features.SWIFT, gpu_features.EXECUTOR, gpu_features.CHECK_DXVK, gpu_features.RELAY,
         gpu_features.ADMISSION, gpu_features.BROKER, gpu_features.DRIVER, gpu_features.SILENT)


class FeatureListsTest(unittest.TestCase):
    def test_every_list_matches_the_canonical_one(self):
        self.assertEqual(gpu_features.problems(REPO), [])

    def copy(self):
        root = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, root)
        for name in FILES:
            (root / name).parent.mkdir(parents=True, exist_ok=True)
            shutil.copy(REPO / name, root / name)
        return root

    def edit(self, root, name, old, new):
        path = root / name
        text = path.read_text()
        self.assertIn(old, text)
        path.write_text(text.replace(old, new, 1))

    def test_a_relay_that_drops_a_feature_is_named(self):
        root = self.copy()
        self.edit(root, gpu_features.RELAY, ", 'silent-success'", '')
        found = gpu_features.problems(root)
        self.assertEqual(len(found), 1)
        self.assertIn('host relay', found[0])
        self.assertIn('lacks silent-success', found[0])

    def test_admission_broker_phone_and_driver_drops_are_named(self):
        root = self.copy()
        self.edit(root, gpu_features.ADMISSION, "'wait-serial', ", '')
        self.edit(root, gpu_features.BROKER, "'guest-set-ids': 0x100000, ", '')
        self.edit(root, gpu_features.SWIFT, ',completion-payloads', '')
        self.edit(root, gpu_features.DRIVER, 'kWaitSerial | kSilentSuccess |', 'kWaitSerial |')
        found = '\n'.join(gpu_features.problems(root))
        self.assertIn('broker admission', found)
        self.assertIn('lacks wait-serial', found)
        self.assertIn('HELLO_FEATURES): lacks guest-set-ids', found)
        self.assertIn('phone app', found)
        self.assertIn('lacks completion-payloads', found)
        self.assertIn('does not offer silent-success', found)

    def test_a_dependency_the_broker_forgets_is_named(self):
        root = self.copy()
        self.edit(root, gpu_features.BROKER, 'NEEDS_COMPLETION_FEED = 0x200000 | ', 'NEEDS_COMPLETION_FEED = ')
        self.assertIn('completion-payloads needs 0x0', '\n'.join(gpu_features.problems(root)))

    def test_expected_session_is_the_offer_the_phone_can_take(self):
        expected = gpu_features.expected(REPO)
        names = set(expected['hello_names'])
        self.assertEqual(names, {f['name'] for f in gpu_features.canonical() if f['phone'] and f['bit']})
        self.assertTrue(int(expected['hello_features'], 16) & gpu_features.CACHE_SESSION)

    def test_a_feature_without_its_requirement_is_not_granted(self):
        needs = {0x800000: 0x280}
        self.assertEqual(gpu_features.granted(0xa00080 | 0x20000, 0xa00080, needs), 0x20080 | 0x200000)


if __name__ == '__main__':
    unittest.main()
