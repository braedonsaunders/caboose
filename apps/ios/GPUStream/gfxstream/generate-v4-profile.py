#!/usr/bin/env python3
"""Generate/check the private v4 forbidden opcode list against the pinned decoder."""
import argparse
import hashlib
import re
from pathlib import Path

PIN = 'f0ce013371a68e85b5a1a1b0cf14ac9ad729f4be'
PRISTINE_DECODER = '5d1e1b5e5603e4f05aa72f11002beb37e3e258ae5f67f66b176d3848574a56a7'
PATCHED_DECODER = 'bb9a61da727873808168d71c65de010f8906fc32ecb6db6350334f50dbb28c99'
MARSHALING = '2174da9a4aaf50d228c36537c6b6fc3c66ccec8e8ce1c6c761e225da1488a302'
PATCHED_INPUTS = {
    'host/vulkan/vk_decoder_global_state.cpp': 'fee1354b16b19b3fb24171a003db511b03347d49daf7061e32347ee7f0677ded',
    'host/vulkan/vk_decoder_global_state.h': '68e18dee40d495306db22ead715079f8fc96505d682dbe6cb909249b58893740',
    'host/vulkan/vk_decoder_internal_structs.h': '8a2a2bbc3aae9555403f94fbf85dc339185d4091f311f183bbf7c06f4657089f',
    'host/vulkan/caboose_guest_gpu_completion.h': '4729d0b4ceac83b8304eabf709d2e9346a9c48b4d1ad5275cc52b9c6127e8c4d',
    'host/features/include/gfxstream/host/features.h': '8c4e029e5717c102711a278c912dc9f1062b97155194f34cbcc1efede7c2c59b',
}
AUDIT_INPUTS = {
    'host/vulkan/vk_decoder_global_state.cpp': 'fee1354b16b19b3fb24171a003db511b03347d49daf7061e32347ee7f0677ded',
    'host/vulkan/vk_decoder_global_state.h': '68e18dee40d495306db22ead715079f8fc96505d682dbe6cb909249b58893740',
    'host/features/include/gfxstream/host/features.h': 'd8e66ce6778cb29403248a2fbaf0143f1ebe2683c9256cfc0a4500db3ad367e3',
    'host/vulkan/caboose_memory_audit.h': '070cbdf15ad4e54770f0f8f3fe3ac7920e2b57f142605c2a8574132c1cbc71aa',
}
SAFE_QUEUE = {'vkQueueSubmit', 'vkQueueSubmit2', 'vkQueueSubmit2KHR',
              'vkQueueBindSparse', 'vkQueueWaitIdle'}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('gfxstream', type=Path)
    parser.add_argument('--check', action='store_true')
    parser.add_argument('--patched', action='store_true', help='verify the 0022/0025-patched decoder')
    parser.add_argument('--memory-audit', action='store_true', help='verify the 0024 diagnostic overlay')
    args = parser.parse_args()
    if args.memory_audit and not args.patched:
        raise SystemExit('--memory-audit requires --patched')
    decoder_path = args.gfxstream / 'host/vulkan/vk_decoder.cpp'
    header_path = args.gfxstream / 'host/vulkan/cereal/common/goldfish_vk_marshaling.h'
    decoder_bytes = decoder_path.read_bytes()
    header_bytes = header_path.read_bytes()
    if hashlib.sha256(decoder_bytes).hexdigest() != (PATCHED_DECODER if args.patched else PRISTINE_DECODER):
        raise SystemExit('decoder SHA-256 does not match the pinned source/patch')
    if hashlib.sha256(header_bytes).hexdigest() != MARSHALING:
        raise SystemExit('marshaling header SHA-256 does not match the pinned source')
    if args.patched:
        expected_inputs = dict(PATCHED_INPUTS)
        if args.memory_audit or (args.gfxstream / 'host/vulkan/caboose_memory_audit.h').exists():
            expected_inputs.update(AUDIT_INPUTS)
        for relative, expected in expected_inputs.items():
            if hashlib.sha256((args.gfxstream / relative).read_bytes()).hexdigest() != expected:
                raise SystemExit(f'patched input SHA-256 mismatch: {relative}')
    decoder = decoder_bytes.decode()
    header = header_bytes.decode()
    names = set(re.findall(r'case OP_(vk\w+)\s*:', decoder))
    definitions = dict(re.findall(r'^#define OP_(vk\w+)\s+(\d+)\s*$', header, re.M))
    host_copy = ('vkCopyMemoryToImage', 'vkCopyImageToMemory', 'vkCopyImageToImage', 'vkTransitionImageLayout')
    forbidden = {name for name in names if 'Async' in name or 'ANDROID' in name or
                 'Swapchain' in name or name.startswith(('vkAcquireNextImage',) + host_copy) or
                 (name.startswith('vkQueue') and name not in SAFE_QUEUE)}
    missing = (forbidden | SAFE_QUEUE) - definitions.keys()
    if missing or not SAFE_QUEUE <= names:
        raise SystemExit(f'pinned decoder definitions/cases missing: {sorted(missing | (SAFE_QUEUE - names))}')
    entries = sorted((int(definitions[name]), name) for name in forbidden)
    if len({value for value, _ in entries}) != len(entries):
        raise SystemExit('duplicate forbidden opcode value')
    content = '// Generated from pinned vk_decoder.cpp and goldfish_vk_marshaling.h.\n' + ''.join(
        f'{value}u, // {name}\n' for value, name in entries)
    output = Path(__file__).with_name('v4-forbidden-opcodes.inc')
    if args.check:
        if output.read_text() != content:
            raise SystemExit('v4 forbidden opcode list differs from source')
    else:
        output.write_text(content)
    print(f'{len(entries)} restricted opcodes; verified source hashes for {PIN}')


if __name__ == '__main__':
    main()
