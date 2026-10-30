"""Source-only wire and range fixtures; native integration remains untested."""
import struct
import unittest

WHOLE = (1 << 64) - 1


def mapped_range(allocation, mapped_offset, mapped_length, offset, size, atom):
    if not mapped_length or mapped_offset > allocation or mapped_length > allocation - mapped_offset:
        raise ValueError('invalid mapping')
    end = mapped_offset + mapped_length
    if not atom or offset < mapped_offset or offset >= end or offset % atom:
        raise ValueError('invalid offset')
    length = end - offset if size == WHOLE else size
    if not length or length > end - offset:
        raise ValueError('invalid size')
    if size == WHOLE:
        if end % atom and end != allocation:
            raise ValueError('unaligned mapping end')
    elif length % atom and offset + length != allocation:
        raise ValueError('unaligned size')
    return length


def parse_reply(data, expected):
    if len(data) < 8:
        raise ValueError('truncated length')
    length, = struct.unpack('=Q', data[:8])
    if length != expected:
        raise ValueError('length mismatch')
    if len(data) < 8 + length:
        raise ValueError('truncated payload')
    return data[8:8 + length], data[8 + length:]


class ShadowProtocolTests(unittest.TestCase):
    def test_partial_mapping_whole_size(self):
        self.assertEqual(mapped_range(1024, 128, 256, 256, WHOLE, 64), 128)
        self.assertEqual(mapped_range(1000, 896, 104, 896, WHOLE, 64), 104)

    def test_invalid_ranges(self):
        for args in [(1024, 128, 256, 64, 64, 64), (1024, 128, 256, 128, 257, 64),
                     (1024, 128, 256, 129, 64, 64), (1024, 128, 256, 128, 65, 64),
                     (1024, 128, 100, 128, WHOLE, 64), (1024, 1020, 9, 1020, 1, 1),
                     (1024, 128, 0, 128, WHOLE, 64)]:
            with self.subTest(args=args), self.assertRaises(ValueError):
                mapped_range(*args)

    def test_reply_fail_closed(self):
        data = struct.pack('=Q', 4) + b'abcd'
        self.assertEqual(parse_reply(data + b'next', 4), (b'abcd', b'next'))
        for payload, expected in [(b'\x04', 4), (data, 3), (data[:-1], 4),
                                  (struct.pack('=Q', WHOLE), 4)]:
            with self.subTest(payload=payload, expected=expected), self.assertRaises(ValueError):
                parse_reply(payload, expected)



    def test_rpc_timing_anchor_requires_exact_single_match(self):
        import prepare_bounded_memory as prep
        sample = '''VkResult VkEncoder::vkQueueSubmit(
    VkQueue queue,
    uint32_t submitCount,
    const VkSubmitInfo* pSubmits,
    VkFence fence,
    uint32_t doLock) {
    (void)doLock;
    bool queueSubmitWithCommandsEnabled =
        sFeatureBits & VULKAN_STREAM_FEATURE_QUEUE_SUBMIT_WITH_COMMANDS_BIT;
    if (!queueSubmitWithCommandsEnabled && doLock) this->lock();
    VkResult vkQueueSubmit_VkResult_return = (VkResult)0;
    stream->read(&vkQueueSubmit_VkResult_return, sizeof(VkResult));
    if (!queueSubmitWithCommandsEnabled && doLock) this->unlock();
    return vkQueueSubmit_VkResult_return;
}
'''
        out = prep.instrument_rpc_call(sample, 'vkQueueSubmit')
        self.assertEqual(out.count('caboose::memory::RpcCallScope caboose_rpc_timing{OP_vkQueueSubmit};'), 1)
        self.assertEqual(out.count('caboose_rpc_timing.lock([&] { this->lock(); });'), 1)
        self.assertEqual(out.count('caboose_rpc_timing.finish(vkQueueSubmit_VkResult_return)'), 1)
        with self.assertRaises(ValueError):
            prep.instrument_rpc_call(out, 'vkQueueSubmit')
        with self.assertRaises(ValueError):
            prep.instrument_rpc_call(sample + sample, 'vkQueueSubmit')


if __name__ == '__main__':
    unittest.main()
