#!/usr/bin/env python3
"""Enable a build-time-only private socket ICD diagnostic on a gated Mesa tree.

Never install this build as a system ICD. The socket peer supplies authenticated
process association and validates the fixed feature handshake.
"""
import hashlib
from pathlib import Path
import sys

DEVICE = 'src/gfxstream/guest/vulkan/gfxstream_vk_device.cpp'
CONNECTION = 'src/gfxstream/guest/vulkan_enc/GfxStreamVulkanConnection.cpp'
MANAGER = 'src/gfxstream/guest/connection-manager/GfxStreamConnectionManager.cpp'
EXPECTED = {
    DEVICE: 'f97f793492c68714d3aa5376604ab3dbcd8a2c046ca10f9b586315978c629c68',
    CONNECTION: '30afdea38aba9c5306e1322e1b543e03855c27bb3e8b4f321af36903a9586a1f',
    MANAGER: '153e4eac8c7a51ba3414613012df2342b9de37ee9545e46cfd3c8b87c82a7ffc',
}


def replace_once(data, old, new):
    if data.count(old) != 1:
        raise ValueError('unexpected source anchor: ' + old[:80])
    return data.replace(old, new, 1)


def apply(root):
    root = Path(root)
    sources = {}
    for name, expected in EXPECTED.items():
        data = (root / name).read_bytes()
        if hashlib.sha256(data).hexdigest() != expected:
            raise ValueError(f'{name}: source hash mismatch')
        sources[name] = data.decode()
    source = sources[DEVICE]
    # These branches exist only in explicitly compiled diagnostic builds. Normal
    # builds keep both gates. Socket selection is still explicit at runtime.
    gate = '    if (std::getenv("CABOOSE_GFXSTREAM_SOCKET")) return VK_ERROR_INCOMPATIBLE_DRIVER;'
    if source.count(gate) != 2:
        raise ValueError('expected two independent socket gates')
    source = source.replace(gate, '#ifndef CABOOSE_GFXSTREAM_PRIVATE_ICD\n' + gate + '\n#endif')
    source = replace_once(source,
        'static gfxstream::vk::VkEncoder* getVulkanEncoder(GfxStreamConnectionManager* mgr) {',
        'static gfxstream::vk::VkEncoder* getVulkanEncoder(GfxStreamConnectionManager* mgr) {\n    if (!mgr) return nullptr;')
    source = replace_once(source,
        '    gfxstream::vk::ResourceTracker::get()->setupCaps(gNoRenderControlEnc);',
        '''#ifdef CABOOSE_GFXSTREAM_PRIVATE_ICD
    if (std::getenv("CABOOSE_GFXSTREAM_SOCKET")) {
        // The validated private hello only permits feature mask zero. This is
        // not a GPU capability declaration; Vulkan queries provide those.
        gNoRenderControlEnc = 1;
    } else
#endif
    gfxstream::vk::ResourceTracker::get()->setupCaps(gNoRenderControlEnc);''')
    source = replace_once(source,
        '    instance->init_failed = (SetupInstanceForProcess() == VK_ERROR_INITIALIZATION_FAILED);',
        '''#ifdef CABOOSE_GFXSTREAM_PRIVATE_ICD
    if (std::getenv("CABOOSE_GFXSTREAM_SOCKET")) {
        VkResult setup = SetupInstanceForProcess();
        if (setup != VK_SUCCESS) { vk_free(pAllocator, instance); return setup; }
        instance->init_failed = false;
    } else
#endif
    instance->init_failed = (SetupInstanceForProcess() == VK_ERROR_INITIALIZATION_FAILED);''')
    sources[DEVICE] = source
    sources[CONNECTION] = replace_once(sources[CONNECTION],
        '    auto* device = VirtGpuDevice::getInstance(kCapsetGfxStreamVulkan);',
        '''#ifdef CABOOSE_GFXSTREAM_PRIVATE_ICD
    if (std::getenv("CABOOSE_GFXSTREAM_SOCKET")) return;
#endif
    auto* device = VirtGpuDevice::getInstance(kCapsetGfxStreamVulkan);''')
    sources[CONNECTION] = '#include <cstdlib>\n' + sources[CONNECTION]
    sources[MANAGER] = replace_once(sources[MANAGER],
        '''    *pClientFlags = 0;
    mStream->commitBuffer(sizeof(unsigned int));''',
        '''    if (!pClientFlags) { mStream->decRef(); mStream = nullptr; return false; }
    *pClientFlags = 0;
    if (mStream->commitBuffer(sizeof(unsigned int)) != 0) {
        mStream->decRef(); mStream = nullptr; return false;
    }''')
    for name, data in sources.items():
        (root / name).write_text(data, encoding='utf-8')


if __name__ == '__main__':
    if len(sys.argv) != 2:
        raise SystemExit('usage: prepare_private_icd.py PREPARED_GATED_MESA_TREE')
    apply(sys.argv[1])
