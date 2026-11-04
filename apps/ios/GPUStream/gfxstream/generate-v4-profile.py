#!/usr/bin/env python3
"""Generate/check the private v4 forbidden opcode list against the pinned decoder."""
import argparse
import hashlib
import re
from pathlib import Path

PIN = 'f0ce013371a68e85b5a1a1b0cf14ac9ad729f4be'
PRISTINE_DECODER = '5d1e1b5e5603e4f05aa72f11002beb37e3e258ae5f67f66b176d3848574a56a7'
PATCHED_DECODER = '4f4af3395d10e411047ebcf6e47ec4e5f358e099783b371aa80d7b6cde9b8203'
MARSHALING = '2174da9a4aaf50d228c36537c6b6fc3c66ccec8e8ce1c6c761e225da1488a302'
PATCHED_INPUTS = {
    'host/vulkan/vk_decoder_global_state.cpp': '04c08cfef5cebf76002e6ca70426507881d7c4c87275957ed14e6bf163e4c664',
    'host/vulkan/vk_decoder_global_state.h': 'b0c3751e3f6f21f8ffbfd6bf58362ad15a384d0689c931fc9090041155b3d611',
    'host/vulkan/vk_decoder_internal_structs.h': '16c97d6bf51cf022f252b06918790fda58017966522883915fe2078975355391',
    'host/vulkan/caboose_guest_gpu_completion.h': '4729d0b4ceac83b8304eabf709d2e9346a9c48b4d1ad5275cc52b9c6127e8c4d',
    'host/features/include/gfxstream/host/features.h': '8c4e029e5717c102711a278c912dc9f1062b97155194f34cbcc1efede7c2c59b',
    'host/vulkan/caboose_guest_set_ids.h': '4815b9565b8691e94a19b61710cdde404ed3b5468a1bc1c6209e8787cfce85c9',
}
AUDIT_INPUTS = {
    'host/vulkan/vk_decoder_global_state.cpp': '04c08cfef5cebf76002e6ca70426507881d7c4c87275957ed14e6bf163e4c664',
    'host/vulkan/vk_decoder_global_state.h': 'b0c3751e3f6f21f8ffbfd6bf58362ad15a384d0689c931fc9090041155b3d611',
    'host/features/include/gfxstream/host/features.h': 'd8e66ce6778cb29403248a2fbaf0143f1ebe2683c9256cfc0a4500db3ad367e3',
    'host/vulkan/caboose_memory_audit.h': '070cbdf15ad4e54770f0f8f3fe3ac7920e2b57f142605c2a8574132c1cbc71aa',
}
# vk_decoder_global_state.cpp after 0027/0028 (A2), 0029 (resource cache), 0040 (guest-device Metal
# objects), display timing, the media latch objects, the shader cache (fork shader-cache),
# executor suspension (fork executor-suspend), pipeline stand-ins (fork pipeline-standin) and the
# queue stall report (fork queue-stall), the lost-device report (fork device-lost) and the Linux
# executor's headless surface (fork linux-headless-executor), and pool set ids kept apart from
# per-call descriptor sets (fork batched-descriptor-sets), and bounded process teardown with the
# device-memory budget (fork lost-owner-teardown), and inline uniform blocks kept offered with
# batched descriptor sets (fork inline-uniform-blocks-with-batched-sets), and per-call sets that
# pass the batched pool accounting get overflow sets (fork per-call-overflow-with-batched), and
# guest-assigned pipelines compiled off the decode thread (fork pipeline-compile-lane), and pools
# whose set ids the guest chose (fork guest-set-ids), and query and memory captures for
# completion records (fork completion-payload-captures), and guest-assigned instance, physical
# device, device and queue handles (fork guest-dispatchable-handles).
RESOURCE_CACHE_INPUTS = {
    'host/vulkan/vk_decoder_global_state.cpp': '04c08cfef5cebf76002e6ca70426507881d7c4c87275957ed14e6bf163e4c664',
    'host/vulkan/caboose_pipeline_cache.h': '3450de5a914b57557b5df681ec0221386b92c67d7d58f10788dc9470da90aa0c',
}
# Queue commands a v4 stream may carry. vkQueueCommitDescriptorSetUpdatesGOOGLE carries the
# descriptor sets a process allocated and wrote in the guest since its last submit (hello
# feature 0x80000, docs/gpu-live.md "Batched descriptor sets"); it is synchronous like a
# submit. Every other vkQueue* command stays forbidden.
SAFE_QUEUE = {'vkQueueSubmit', 'vkQueueSubmit2', 'vkQueueSubmit2KHR',
              'vkQueueBindSparse', 'vkQueueWaitIdle', 'vkQueueCommitDescriptorSetUpdatesGOOGLE'}


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
    decoder_hash = hashlib.sha256(decoder_bytes).hexdigest()
    valid_decoder_hashes = {PATCHED_DECODER} if args.patched else {PRISTINE_DECODER}
    if decoder_hash not in valid_decoder_hashes:
        raise SystemExit('decoder SHA-256 does not match the pinned source/patch')
    if hashlib.sha256(header_bytes).hexdigest() != MARSHALING:
        raise SystemExit('marshaling header SHA-256 does not match the pinned source')
    if args.patched:
        expected_inputs = dict(PATCHED_INPUTS)
        if args.memory_audit or (args.gfxstream / 'host/vulkan/caboose_memory_audit.h').exists():
            expected_inputs.update(AUDIT_INPUTS)
        if (args.gfxstream / 'host/vulkan/caboose_pipeline_cache.h').exists():
            expected_inputs.update(RESOURCE_CACHE_INPUTS)
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
