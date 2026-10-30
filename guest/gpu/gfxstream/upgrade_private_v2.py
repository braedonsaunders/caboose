#!/usr/bin/env python3
"""Upgrade the retained v1 private diagnostic Mesa tree for the v2 probe."""
import hashlib
from pathlib import Path
import sys
import prepare_probe

HERE = Path(__file__).resolve().parent
DEVICE = Path('src/gfxstream/guest/vulkan/gfxstream_vk_device.cpp')
SOCKET = Path('src/gfxstream/guest/connection-manager/SocketStream.cpp')
VULKAN = Path('src/gfxstream/guest/vulkan')
EXPECTED = {
    DEVICE: 'a8b3e5e21e5d0ae5381e9224647580c102da2378839a9b1960c728386bdd3a8c',
    SOCKET: 'd6f69d344f8636d059b43db047d7b24bbd4bc4d34bf36922a71c5703c555c7e8',
    VULKAN / 'meson.build': prepare_probe.EXPECTED,
}
OLD = '''        // The validated private hello only permits feature mask zero. This is
        // not a GPU capability declaration; Vulkan queries provide those.
        gNoRenderControlEnc = 1;'''
NEW = '''        // getConnectionManager validated the private v2 feature handshake.
        // This is a wire-format feature, not a Vulkan hardware capability.
        struct GfxStreamVkFeatureInfo features = {};
        features.hasVulkanNullOptionalStrings = true;
        gfxstream::vk::ResourceTracker::get()->setupFeatures(&features);
        gNoRenderControlEnc = 1;'''


def apply(root):
    root = Path(root)
    for rel, digest in EXPECTED.items():
        if hashlib.sha256((root / rel).read_bytes()).hexdigest() != digest:
            raise ValueError(f'{rel}: retained v1 source hash mismatch')
    device = (root / DEVICE).read_text()
    if device.count(OLD) != 1:
        raise ValueError('expected one private v1 setup block')
    for name in ('encoder_probe.cpp', 'buffer_probe.cpp', 'compute_probe.cpp', 'draw_probe.cpp'):
        if (root / VULKAN / name).exists():
            raise FileExistsError(root / VULKAN / name)
    # Only known v1 paths in the isolated diagnostic tree are changed.
    prepare_probe.apply(root)
    (root / DEVICE).write_text(device.replace(OLD, NEW, 1))
    (root / SOCKET).write_bytes((HERE / 'SocketStream.cpp').read_bytes())


if __name__ == '__main__':
    if len(sys.argv) != 2:
        raise SystemExit('usage: upgrade_private_v2.py RETAINED_PRIVATE_MESA')
    apply(sys.argv[1])
