import ctypes as C
import struct
import unittest
from x11_record import Intercept, Range, pointer_header

class RecordParserTests(unittest.TestCase):
    def test_truncated_ge_and_core_byte_orders(self):
        for endian in ('<', '>'):
            for typ in (4, 5, 6):
                header = bytearray(32)
                header[0] = 35
                header[1] = 131
                struct.pack_into(endian+'I', header, 4, 20)
                struct.pack_into(endian+'HHIIIII', header, 8, typ, 2, 1234, 5, 576, 123, 0)
                self.assertEqual(pointer_header(header, endian),
                    dict(kind='XI', type=typ, recipient=123, child=0, time=1234, button=5))
                header[0] = typ
                header[1] = 5
                struct.pack_into(endian+'IIII', header, 4, 1234, 576, 123, 0)
                self.assertEqual(pointer_header(header, endian),
                    dict(kind='core', type=typ, recipient=123, child=0, time=1234, button=5))

    def test_keys_and_short_records_excluded(self):
        self.assertIsNone(pointer_header(bytes(31)))
        for typ in (2, 3):
            header = bytearray(32)
            header[0] = typ
            self.assertIsNone(pointer_header(header))
            header[0] = 35
            header[1] = 131
            struct.pack_into('<H', header, 8, typ)
            self.assertIsNone(pointer_header(header))

    def test_other_generic_extension_excluded(self):
        header = bytearray(32)
        header[0], header[1] = 35, 132
        struct.pack_into('<H', header, 8, 4)
        self.assertIsNone(pointer_header(header, xi_opcode=131))

    def test_recipient_filter_excludes_other_window_trees(self):
        for typ in (4, 5, 6, 35):
            header = bytearray(32)
            header[0] = typ
            if typ == 35:
                header[1] = 131
                struct.pack_into('<HHIIIII', header, 8, 6, 2, 1234, 0, 576, 123, 456)
            else:
                struct.pack_into('<IIII', header, 4, 1234, 576, 123, 456)
            self.assertIsNotNone(pointer_header(header, recipients={123}))
            self.assertIsNotNone(pointer_header(header, recipients={456}))
            self.assertIsNone(pointer_header(header, recipients={789}))
            self.assertIsNone(pointer_header(header, recipients=set()))

    def test_lp64_header_layout(self):
        if C.sizeof(C.c_void_p) != 8:
            self.skipTest('LP64 ABI check')
        self.assertEqual(C.sizeof(Intercept), 48)
        self.assertEqual(Intercept.data.offset, 32)
        self.assertEqual(Intercept.data_len.offset, 40)
        self.assertEqual(Range.delivered.offset, 16)
        self.assertEqual(C.sizeof(Range), 32)

if __name__ == '__main__':
    unittest.main()
