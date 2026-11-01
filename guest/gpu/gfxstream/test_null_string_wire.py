"""Pinned generated codec vectors; runtime wire validation remains separate.

The pointer bytes are presence markers; actual non-null pointer values vary.
These byte fixtures correspond to VkEncoder.cpp:1086-1166 and the pinned
host vk_decoder.cpp:979-1012 with NULL_OPTIONAL_STRINGS enabled.
"""
import hashlib
import struct
import unittest
from pathlib import Path

HERE = Path(__file__).parent


def layer_field(value):
    if value is None:
        return bytes(8)
    return bytes.fromhex('0000000000000001') + struct.pack('>I', len(value)) + value


def decode_layer(data):
    if len(data) < 8:
        raise ValueError('truncated marker')
    marker = int.from_bytes(data[:8], 'big')
    if not marker:
        if len(data) != 8:
            raise ValueError('trailing bytes')
        return None
    if len(data) < 12:
        raise ValueError('truncated length')
    length = int.from_bytes(data[8:12], 'big')
    if len(data) != 12 + length:
        raise ValueError('incorrect length')
    return data[12:]


class NullStringWire(unittest.TestCase):
    def test_distinct_vectors(self):
        vectors = [
            (None, '0000000000000000'),
            (b'', '000000000000000100000000'),
            (b'VK_LAYER_KHRONOS_validation', '00000000000000010000001b564b5f4c415945525f4b48524f4e4f535f76616c69646174696f6e'),
            (b'unknown', '000000000000000100000007756e6b6e6f776e'),
        ]
        for value, expected in vectors:
            with self.subTest(value=value):
                data = bytes.fromhex(expected)
                self.assertEqual(layer_field(value), data)
                self.assertEqual(decode_layer(data), value)

    def test_pinned_generated_encoder_evidence(self):
        raw = (HERE / 'fixtures/mesa-enumerate-instance-extension-properties.cpp').read_bytes()
        self.assertEqual(hashlib.sha256(raw).hexdigest(),
                         '70def7921b0a04ec776f2c0aa9163ad46f8a562ea5087499e712a8bd0cab6193')
        source = raw.decode()
        self.assertIn('if (sFeatureBits & VULKAN_STREAM_FEATURE_NULL_OPTIONAL_STRINGS_BIT)', source)
        self.assertIn('if (stream->getFeatureBits() & VULKAN_STREAM_FEATURE_NULL_OPTIONAL_STRINGS_BIT)', source)
        self.assertIn('uint64_t cgen_var_0 = (uint64_t)(uintptr_t)local_pLayerName;', source)
        self.assertIn('gfxstream::aemu::Stream::toBe64', source)
        self.assertIn('gfxstream::aemu::Stream::toBe32', source)
        self.assertIn('uint32_t l = local_pLayerName ? strlen(local_pLayerName) : 0;', source)

    def test_truncations_rejected(self):
        for data in (bytes(7), bytes.fromhex('0000000000000001'),
                     bytes.fromhex('00000000000000010000000261')):
            with self.assertRaises(ValueError):
                decode_layer(data)

    def test_private_setup_and_handshake_are_exact(self):
        patch = (HERE / 'driver/patches/0001-socket-transport.patch').read_text()
        self.assertIn('features.hasVulkanNullOptionalStrings = true;', patch)
        socket = (HERE / 'SocketStream.cpp').read_text()
        # The reply must equal the hello outside the feature mask, which may only add
        # features that were offered.
        self.assertIn('!std::memcmp(reply, kHello, 12)', socket)
        self.assertIn('!std::memcmp(reply + 16, kHello + 16, sizeof(kHello) - 16)', socket)
        self.assertIn('(accepted & required) == required && !(*features & ~offered)', socket)
        self.assertIn("'C','B','G','L','R','E','F','1', 2,0,0,0, 0x10,0,0,0", socket)
        self.assertIn("'C','B','G','L','R','E','F','1', 3,0,0,0, 0x30,0,0,0", socket)
        self.assertIn('errno = EPROTO', socket)


if __name__ == '__main__':
    unittest.main()
