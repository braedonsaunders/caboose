#!/usr/bin/env python3
"""Generate/check the private v4 forbidden opcode list against the pinned decoder."""
import argparse
import re
from pathlib import Path

PIN = 'f0ce013371a68e85b5a1a1b0cf14ac9ad729f4be'
SAFE_QUEUE = {'vkQueueSubmit', 'vkQueueSubmit2', 'vkQueueSubmit2KHR',
              'vkQueueBindSparse', 'vkQueueWaitIdle'}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('gfxstream', type=Path)
    parser.add_argument('--check', action='store_true')
    args = parser.parse_args()
    decoder = (args.gfxstream / 'host/vulkan/vk_decoder.cpp').read_text()
    header = (args.gfxstream / 'host/vulkan/cereal/common/goldfish_vk_marshaling.h').read_text()
    names = set(re.findall(r'case OP_(vk\w+)\s*:', decoder))
    definitions = dict(re.findall(r'^#define OP_(vk\w+)\s+(\d+)\s*$', header, re.M))
    forbidden = {name for name in names if 'Async' in name or 'ANDROID' in name or
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
    print(f'{len(entries)} restricted opcodes; expected pin {PIN}')


if __name__ == '__main__':
    main()
