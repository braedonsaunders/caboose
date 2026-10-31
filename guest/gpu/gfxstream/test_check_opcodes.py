import unittest

from check_opcodes import opcodes


class OpcodeTests(unittest.TestCase):
    def test_definitions_and_whitespace(self):
        self.assertEqual(opcodes(b'#define OP_vkCreateInstance 20000\n # define OP_vkDestroyInstance 20001\n'),
                         {'OP_vkCreateInstance': 20000, 'OP_vkDestroyInstance': 20001})

    def test_conflicts_and_empty_fail(self):
        with self.assertRaises(ValueError):
            opcodes(b'#define OP_vkX 1\n#define OP_vkX 2\n')
        with self.assertRaises(ValueError):
            opcodes(b'not a schema')


if __name__ == '__main__':
    unittest.main()
