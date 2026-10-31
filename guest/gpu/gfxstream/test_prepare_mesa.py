import unittest
from prepare_mesa import replace_once


class PatchTests(unittest.TestCase):
    def test_replace_once_requires_unique_anchor(self):
        self.assertEqual(replace_once('abc', 'b', 'X'), 'aXc')
        for data in ('abc', 'bb'):
            with self.assertRaises(ValueError):
                replace_once(data, 'b' if data == 'bb' else 'z', 'X')


if __name__ == '__main__':
    unittest.main()
