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
TRACKER = 'src/gfxstream/guest/vulkan_enc/ResourceTracker.h'
PIN = '541c56aa3fd24027ed46ae350287d21dcd56c901'
HASHES = {
    DEVICE: 'eb57b7e5bf60f2826007a84f0078fd8f91e2ec06ee4a712f09841cec383d33b1',
    MESON: 'cc654a2f5dba2c53779c4239cbb9318ae20ce533a9a66fa4a2aec93f75963187',
    TRACKER: 'e9329507e9c0e3a3482fe9276b29fb670605a69dc9364c008bc58c67716ca1e6',
}


def once(text, old, new):
    if text.count(old) != 1:
        raise ValueError('unexpected Mesa integration anchor: ' + old[:100])
    return text.replace(old, new, 1)


def transform(device, meson, tracker):
    if '#ifndef CABOOSE_GFXSTREAM_PRIVATE_ICD' not in device:
        raise ValueError('requires prepare_private_icd.py diagnostic gate')
    if 'caboose_surface' in device or 'caboose-wsi' in meson:
        raise ValueError('surface patch already applied')
    device = once(device, '#include "vk_util.h"',
                  '#include "vk_util.h"\nstatic GfxStreamConnectionManager* getConnectionManager(void);\n'
                  '#include "caboose-wsi/mesa_surface.inc"')
    device = once(device,
                  '        gfxstream::vk::ResourceTracker::get()->setupFeatures(&features);\n        gNoRenderControlEnc = 1;',
                  '        gfxstream::vk::ResourceTracker::get()->setupFeatures(&features);\n'
                  '        if (!caboose_surface::profileReady()) return VK_ERROR_INCOMPATIBLE_DRIVER;\n'
                  '        gNoRenderControlEnc = 1;')
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
    device = once(device,
                  '    result = vk_device_init(&gfxstream_device->vk, &gfxstream_physicalDevice->vk,',
                  '    caboose_surface::install(dispatch_table);\n'
                  '    result = vk_device_init(&gfxstream_device->vk, &gfxstream_physicalDevice->vk,')
    device = once(device, '    MESA_TRACE_SCOPE("vkDestroyDevice");',
                  '    MESA_TRACE_SCOPE("vkDestroyDevice");\n'
                  '    if (device && !caboose_surface::beforeDestroyDevice(device)) return;')
    device = once(device, '    MESA_TRACE_SCOPE("vkCreateDevice");',
                  '    MESA_TRACE_SCOPE("vkCreateDevice");\n'
                  '    VkResult privateFeatures = caboose_surface::validateDeviceCreate(pCreateInfo);\n'
                  '    if (privateFeatures != VK_SUCCESS) return privateFeatures;')
    meson = once(meson, "    'gfxstream_vk_wsi.cpp',", "    'gfxstream_vk_wsi.cpp',\n    'caboose-wsi/client.cpp',")
    meson = once(meson, "    gfxstream_vk_wsi_args += '-DGFXSTREAM_VK_WAYLAND'" if
                 "    gfxstream_vk_wsi_args += '-DGFXSTREAM_VK_WAYLAND'" in meson else
                 "  gfxstream_vk_wsi_args += '-DGFXSTREAM_VK_WAYLAND'",
                 "  gfxstream_vk_wsi_args += '-DGFXSTREAM_VK_WAYLAND'\n  gfxstream_deps += dep_wayland_client")
    tracker = once(tracker, '    uint32_t getStreamFeatures() const;', '''    uint32_t getStreamFeatures() const;
    // Read-only proof that setupFeatures actually selected the private sync profile.
    bool cabooseSynchronousProfile() const {
        return mFeatureInfo.setupComplete && mFeatureInfo.hasVulkanNullOptionalStrings &&
            !mFeatureInfo.hasVulkanAsyncQueueSubmit && !mFeatureInfo.hasDeferredVulkanCommands &&
            !mFeatureInfo.hasVulkanAsyncQsri && !mFeatureInfo.hasVulkanQueueSubmitWithCommands &&
            !mFeatureInfo.hasDirectMem && !mFeatureInfo.hasVirtioGpuNext &&
            !mFeatureInfo.hasVulkanBatchedDescriptorSetUpdate;
    }''')
    return device, meson, tracker


def apply(root, check=False):
    root = Path(root)
    revision = subprocess.check_output(['git', '-C', str(root), 'rev-parse', 'HEAD'], text=True).strip()
    if revision != PIN:
        raise ValueError('unexpected Mesa HEAD')
    for name, expected in HASHES.items():
        original = subprocess.check_output(['git', '-C', str(root), 'show', 'HEAD:' + name])
        if hashlib.sha256(original).hexdigest() != expected:
            raise ValueError('upstream hash mismatch: ' + name)
    device, meson, tracker = transform((root / DEVICE).read_text(), (root / MESON).read_text(),
                                      (root / TRACKER).read_text())
    target = (root / DEVICE).parent / 'caboose-wsi'
    if target.exists():
        raise ValueError('override destination already exists')
    if check:
        return
    target.mkdir()
    for name in ('client.h', 'client.cpp', 'wire.h', 'mesa_surface.inc', 'mesa_swapchain.inc'):
        shutil.copyfile(HERE / 'virtual-wsi' / name, target / name)
    (root / DEVICE).write_text(device)
    (root / MESON).write_text(meson)
    (root / TRACKER).write_text(tracker)


if __name__ == '__main__':
    if len(sys.argv) not in (2, 3) or (len(sys.argv) == 3 and sys.argv[2] != '--check'):
        raise SystemExit('usage: prepare_virtual_wsi_surface.py PREPARED_PRIVATE_MESA [--check]')
    apply(sys.argv[1], len(sys.argv) == 3)
