#!/usr/bin/env python3
"""Apply the experimental, fail-closed socket integration to a pinned Mesa tree."""
import hashlib
from pathlib import Path
import shutil
import subprocess
import sys

HERE = Path(__file__).resolve().parent
SOURCES = {
    'src/gfxstream/guest/connection-manager/GfxStreamConnectionManager.cpp': '3838ad785ac5d7d54c40a34bdae73b120ae9120606c06160cc63b81a44a9bd6b',
    'src/gfxstream/guest/connection-manager/meson.build': '9000c2373ea57105510a981cb15300ad6524c46fcdbbf86e8efb0a5832b140a3',
    'src/gfxstream/guest/vulkan/gfxstream_vk_device.cpp': 'eb57b7e5bf60f2826007a84f0078fd8f91e2ec06ee4a712f09841cec383d33b1',
}


def replace_once(text, old, new):
    if text.count(old) != 1:
        raise ValueError('unexpected upstream source: ' + old)
    return text.replace(old, new, 1)


def prepare(root):
    revision = subprocess.check_output(['git', '-C', str(root), 'rev-parse', 'HEAD'], text=True).strip()
    if revision != '541c56aa3fd24027ed46ae350287d21dcd56c901':
        raise ValueError('unexpected Mesa HEAD')
    if subprocess.check_output(['git', '-C', str(root), 'status', '--porcelain', '--untracked-files=no'], text=True):
        raise ValueError('Mesa checkout has tracked modifications')
    paths = {name: root / name for name in SOURCES}
    contents = {}
    for name, path in paths.items():
        data = path.read_bytes()
        if hashlib.sha256(data).hexdigest() != SOURCES[name]:
            raise ValueError(f'{name}: source hash mismatch')
        contents[name] = data.decode('utf-8')
    manager, meson, device = SOURCES
    contents[manager] = replace_once(contents[manager], '#include <cerrno>', '#include <cerrno>\n#include <cstdlib>\n#include "SocketStream.h"')
    contents[manager] = replace_once(contents[manager], '    switch (mTransportType) {', '''    if (const char* path = std::getenv("CABOOSE_GFXSTREAM_SOCKET")) {
        if (!*path) return false;
        auto stream = new CabooseSocketStream(STREAM_BUFFER_SIZE);
        if (stream->connect(path) < 0) { delete stream; return false; }
        mStream = stream;
    } else switch (mTransportType) {''')
    contents[meson] = replace_once(contents[meson], "    'GfxStreamConnectionManager.cpp',", "    'GfxStreamConnectionManager.cpp',\n    'SocketStream.cpp',")
    # The socket path cannot yet implement host-visible Vulkan memory or process
    # association. Reject it before connecting or exposing a physical device.
    contents[device] = replace_once(contents[device], 'static VkResult SetupInstanceForProcess(void) {', '''static VkResult SetupInstanceForProcess(void) {
    if (std::getenv("CABOOSE_GFXSTREAM_SOCKET")) return VK_ERROR_INCOMPATIBLE_DRIVER;''')
    contents[device] = '#include <cstdlib>\n' + contents[device]
    target = root / 'src/gfxstream/guest/connection-manager'
    for name in ('SocketStream.h', 'SocketStream.cpp'):
        if (target / name).exists():
            raise ValueError(f'{target / name}: already exists')
    for name, text in contents.items():
        paths[name].write_text(text, encoding='utf-8')
    for name in ('SocketStream.h', 'SocketStream.cpp'):
        shutil.copyfile(HERE / name, target / name)


if __name__ == '__main__':
    if len(sys.argv) != 2:
        raise SystemExit('usage: prepare_mesa.py MESA_SOURCE_TREE')
    prepare(Path(sys.argv[1]))
