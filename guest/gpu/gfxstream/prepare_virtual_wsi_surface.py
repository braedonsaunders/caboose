#!/usr/bin/env python3
"""Add inactive-by-default native Wayland query overrides to a private Mesa tree.

Checks the pinned upstream blobs and every modified integration anchor. Existing
nonoverlapping private patches are retained. Does not change prepare_mesa.py.
"""
import hashlib
from pathlib import Path
import shutil
import subprocess
import sys

HERE = Path(__file__).resolve().parent
DEVICE = 'src/gfxstream/guest/vulkan/gfxstream_vk_device.cpp'
MESON = 'src/gfxstream/guest/vulkan/meson.build'
PIN = '541c56aa3fd24027ed46ae350287d21dcd56c901'
HASHES = {
    DEVICE: 'eb57b7e5bf60f2826007a84f0078fd8f91e2ec06ee4a712f09841cec383d33b1',
    MESON: 'cc654a2f5dba2c53779c4239cbb9318ae20ce533a9a66fa4a2aec93f75963187',
}


def once(text, old, new):
    if text.count(old) != 1:
        raise ValueError('unexpected Mesa integration anchor: ' + old[:100])
    return text.replace(old, new, 1)


def transform(device, meson):
    if '#ifndef CABOOSE_GFXSTREAM_PRIVATE_ICD' not in device:
        raise ValueError('requires prepare_private_icd.py diagnostic gate')
    if 'caboose_surface' in device or 'caboose-wsi' in meson:
        raise ValueError('surface patch already applied')
    device = once(device, '#include "vk_util.h"',
                  '#include "vk_util.h"\n#include "caboose-wsi/mesa_surface.inc"')
    for anchor in (
        '    // Initialize the mesa object\n',
        '    result = vk_instance_init(&instance->vk, extensions, &dispatch_table, pCreateInfo, pAllocator);',
    ):
        device = once(device, anchor, '    caboose_surface::install(dispatch_table);\n' + anchor)
    device = once(device, '    get_device_extensions(internal_object, &supported_extensions);',
                  '    get_device_extensions(internal_object, &supported_extensions);\n'
                  '    caboose_surface::gate(supported_extensions);')
    device = once(device, '    return retTablePtr;',
                  '    caboose_surface::gate(*retTablePtr);\n    return retTablePtr;')
    device = once(device, '    MESA_TRACE_SCOPE("vkDestroyInstance");',
                  '    MESA_TRACE_SCOPE("vkDestroyInstance");\n'
                  '    if (_instance && !caboose_surface::beforeDestroyInstance(_instance)) return;')
    meson = once(meson, "    'gfxstream_vk_wsi.cpp',", "    'gfxstream_vk_wsi.cpp',\n    'caboose-wsi/client.cpp',")
    meson = once(meson, "    gfxstream_vk_wsi_args += '-DGFXSTREAM_VK_WAYLAND'" if
                 "    gfxstream_vk_wsi_args += '-DGFXSTREAM_VK_WAYLAND'" in meson else
                 "  gfxstream_vk_wsi_args += '-DGFXSTREAM_VK_WAYLAND'",
                 "  gfxstream_vk_wsi_args += '-DGFXSTREAM_VK_WAYLAND'\n  gfxstream_deps += dep_wayland_client")
    return device, meson


def apply(root, check=False):
    root = Path(root)
    revision = subprocess.check_output(['git', '-C', str(root), 'rev-parse', 'HEAD'], text=True).strip()
    if revision != PIN:
        raise ValueError('unexpected Mesa HEAD')
    for name, expected in HASHES.items():
        original = subprocess.check_output(['git', '-C', str(root), 'show', 'HEAD:' + name])
        if hashlib.sha256(original).hexdigest() != expected:
            raise ValueError('upstream hash mismatch: ' + name)
    device, meson = transform((root / DEVICE).read_text(), (root / MESON).read_text())
    target = (root / DEVICE).parent / 'caboose-wsi'
    if target.exists():
        raise ValueError('override destination already exists')
    if check:
        return
    target.mkdir()
    for name in ('client.h', 'client.cpp', 'wire.h', 'mesa_surface.inc'):
        shutil.copyfile(HERE / 'virtual-wsi' / name, target / name)
    (root / DEVICE).write_text(device)
    (root / MESON).write_text(meson)


if __name__ == '__main__':
    if len(sys.argv) not in (2, 3) or (len(sys.argv) == 3 and sys.argv[2] != '--check'):
        raise SystemExit('usage: prepare_virtual_wsi_surface.py PREPARED_PRIVATE_MESA [--check]')
    apply(sys.argv[1], len(sys.argv) == 3)
