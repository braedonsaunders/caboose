import ast
import hashlib
from pathlib import Path
import re
import struct
import unittest


class HandshakeFixture(unittest.TestCase):
    def test_cpp_hello_pins_exact_contract(self):
        source = (Path(__file__).parent / 'SocketStream.cpp').read_text()
        match = re.search(r'kHello\[48\]\s*=\s*\{([^}]*)\}', source, re.S)
        self.assertIsNotNone(match)
        body = match.group(1)
        live = re.search(r'#if defined\(CABOOSE_GFXSTREAM_PRIVATE_LIVE\)\s*(.*?)\s*#else\s*(.*?)\s*#endif', body, re.S)
        self.assertIsNotNone(live)
        shared = body[live.end():]
        def parse(prefix):
            return bytes(ord(ast.literal_eval(token)) if token.startswith("'") else int(token, 0)
                         for raw in (prefix + shared).split(',') if (token := raw.strip()))
        v3, data = parse(live.group(1)), parse(live.group(2))
        expected_source = (b'caboose-gfxstream-private-v1\n'
                           b'gfxstream=f0ce013371a68e85b5a1a1b0cf14ac9ad729f4be\n'
                           b'mesa=541c56aa3fd24027ed46ae350287d21dcd56c901\n')
        self.assertEqual(data, b'CBGLREF1' + struct.pack('<II', 2, 0x10) + hashlib.sha256(expected_source).digest())
        self.assertEqual(v3, b'CBGLREF1' + struct.pack('<II', 3, 0x30) + hashlib.sha256(expected_source).digest())
        self.assertIn('Private live transport requires the private diagnostic ICD build', source)


if __name__ == '__main__':
    unittest.main()
