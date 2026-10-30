import unittest
import prepare_private_icd as private


class PrivateIcdTests(unittest.TestCase):
    def test_patch_rejects_ambiguous_anchor(self):
        with self.assertRaises(ValueError):
            private.replace_once('same same', 'same', 'changed')
        with self.assertRaises(ValueError):
            private.replace_once('unrelated', 'same', 'changed')

    def test_pinned_inputs_include_connection_manager_and_device(self):
        self.assertEqual(set(private.EXPECTED), {private.DEVICE, private.CONNECTION, private.MANAGER})
        self.assertTrue(all(len(value) == 64 for value in private.EXPECTED.values()))


if __name__ == '__main__':
    unittest.main()
