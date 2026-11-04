"""The guest's silent-success commands are the decoder's (docs/gpu-live.md, "Silent success")."""
import re
import sys
from pathlib import Path
import unittest

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE / 'driver'))
import check_silent_success  # noqa: E402

DECODER = HERE.parents[2] / 'apps/ios/GPUStream/gfxstream/silent-success-opcodes.inc'
GUEST = HERE / 'bounded-memory/silent_success.h'


def opcodes(text):
    return {int(value): name for value, name in re.findall(r'^\s*(\d+)u,\s*// (vk\w+)', text, re.M)}


class SilentSuccessListTest(unittest.TestCase):
    def test_guest_and_decoder_name_the_same_commands(self):
        guest = opcodes(GUEST.read_text().split('kOpcodes[] = {', 1)[1].split('};', 1)[0])
        decoder = opcodes(DECODER.read_text())
        self.assertTrue(decoder)
        self.assertEqual(guest, decoder)

    def test_header_list_is_what_the_tree_check_reads(self):
        self.assertEqual(set(check_silent_success.guest_opcodes(GUEST.read_text())),
                         set(opcodes(DECODER.read_text())))

    def test_tree_check_compares_deferred_replies_with_the_list(self):
        encoder = '''
VkResult VkEncoder::vkCreateBuffer(VkDevice device, uint32_t doLock) {
    uint32_t opcode_vkCreateBuffer = OP_vkCreateBuffer;
    caboose::memory::deferredReplies.addHandleCreate(this, cgen_var_2, packetSize_vkCreateBuffer);
}

void VkEncoder::vkFreeCommandBuffers(VkDevice device, uint32_t doLock) {
    uint32_t opcode_vkFreeCommandBuffers = OP_vkFreeCommandBuffers;
}

VkResult VkEncoder::vkEndCommandBuffer(VkCommandBuffer commandBuffer, uint32_t doLock) {
    const bool cabooseSilent = caboose::silent::replyMode().silent(this);
    uint32_t opcode_vkEndCommandBuffer = OP_vkEndCommandBuffer;
    if (!cabooseSilent) caboose_read_profile::read(stream, &result, sizeof(VkResult));
}

VkResult VkEncoder::vkResetFences(VkDevice device, uint32_t doLock) {
    uint32_t opcode_vkResetFences = OP_vkResetFences;
    caboose::memory::deferredReplies.add(this, 1, packetSize_vkResetFences);
}
'''
        defines = ('#define OP_vkCreateBuffer 20050\n#define OP_vkFreeCommandBuffers 20089\n'
                   '#define OP_vkEndCommandBuffer 20091\n#define OP_vkResetFences 20036\n')
        deferred, void = check_silent_success.encoder_commands(encoder, defines)
        self.assertEqual(deferred, {20050: 'vkCreateBuffer'})
        self.assertEqual(void, {20089, 20091})
        self.assertEqual(check_silent_success.differences(deferred, void, {20050, 20089, 20091}), [])
        self.assertTrue(check_silent_success.differences(deferred, void, {20050}) == [])
        self.assertIn('vkCreateBuffer', ' '.join(check_silent_success.differences(deferred, void, {20089})))
        self.assertTrue(check_silent_success.differences(deferred, void, {20050, 20036}))


if __name__ == '__main__':
    unittest.main()
