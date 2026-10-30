#!/usr/bin/env python3
"""Fix socket-mode CreateInstance in a tree prepared by prepare_mesa.py."""
import hashlib
from pathlib import Path
import sys

EXPECTED = '1e88a35c903db9e2b1520511c3cc38e2497fa2a883ff17647e7dbfbb4f472228'
PATH = 'src/gfxstream/guest/vulkan/gfxstream_vk_device.cpp'
ANCHOR = '''    MESA_TRACE_SCOPE("vkCreateInstance");

    struct gfxstream_vk_instance* instance;'''
REPLACEMENT = '''    MESA_TRACE_SCOPE("vkCreateInstance");
    // Socket transport is experimental. Fail before allocating an instance or
    // looking up a thread-local encoder until the complete path is ready.
    if (std::getenv("CABOOSE_GFXSTREAM_SOCKET")) return VK_ERROR_INCOMPATIBLE_DRIVER;

    struct gfxstream_vk_instance* instance;'''


def apply(root):
    path = Path(root) / PATH
    data = path.read_bytes()
    if hashlib.sha256(data).hexdigest() != EXPECTED:
        raise ValueError('unexpected prepared gfxstream_vk_device.cpp')
    source = data.decode('utf-8')
    if source.count(ANCHOR) != 1:
        raise ValueError('CreateInstance anchor is not unique')
    path.write_text(source.replace(ANCHOR, REPLACEMENT, 1), encoding='utf-8')


if __name__ == '__main__':
    if len(sys.argv) != 2:
        raise SystemExit('usage: fix_instance_gate.py PREPARED_MESA_TREE')
    apply(sys.argv[1])
