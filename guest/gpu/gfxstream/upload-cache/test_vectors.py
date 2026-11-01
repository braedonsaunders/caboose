"""The upload cache's wire vectors are well formed (the hashes are checked by the phone's and
the guest driver's tests, which have BLAKE3)."""
import json
from pathlib import Path
import struct
import unittest

V = json.loads(Path(__file__).with_name('vectors.json').read_text())
PIECE = (1 << 63) | 4096


class VectorTests(unittest.TestCase):
    def test_inventory(self):
        self.assertEqual(struct.unpack('<IIII', bytes.fromhex(V['inventory_packet'])), (0x4342FE11, 16, 1, 0))
        count, allowance = struct.unpack_from('<II', bytes.fromhex(V['inventory_reply_a_b_allowance_65536']))
        reply = bytes.fromhex(V['inventory_reply_a_b_allowance_65536'])
        self.assertEqual((count, allowance, len(reply)), (2, 65536, 8 + 2 * 16))
        self.assertEqual(reply[8:24], bytes.fromhex(V['blake3_piece_a'])[:16])
        self.assertEqual(reply[24:40], bytes.fromhex(V['blake3_piece_b'])[:16])
        self.assertGreater(struct.unpack_from('<I', bytes.fromhex(V['invalid']['inventory_reply_too_many']))[0], 262144)

    def test_pieces(self):
        a = bytes(i % 251 for i in range(4096))
        store = bytes.fromhex(V['piece_store_a'])
        self.assertEqual(struct.unpack_from('<QI', store), (PIECE, 1))
        self.assertEqual(store[12:], a)
        stored = bytes.fromhex(V['piece_stored_a'])
        self.assertEqual(struct.unpack_from('<QI', stored), (PIECE, 2))
        self.assertEqual(stored[12:], bytes.fromhex(V['blake3_piece_a'])[:16])
        literal = bytes.fromhex(V['literal_a'])
        self.assertEqual((struct.unpack_from('<Q', literal)[0], literal[8:]), (4096, a))
        for name, wire in V['invalid'].items():
            if name.startswith('inventory'):
                continue
            length, kind = struct.unpack_from('<QI', bytes.fromhex(wire))
            valid_kind = kind == 1 and len(wire) // 2 == 12 + 4096 or kind == 2 and len(wire) // 2 == 28
            self.assertFalse(length == PIECE and valid_kind and wire[24:] != '00' * 16, name)


if __name__ == '__main__':
    unittest.main()
