#!/usr/bin/env python3
"""Add a private encoder probe target to the exact prepared Mesa tree."""
import hashlib
from pathlib import Path
import shutil
import sys

HERE = Path(__file__).resolve().parent
EXPECTED = 'cc654a2f5dba2c53779c4239cbb9318ae20ce533a9a66fa4a2aec93f75963187'
TARGET = '''
# Caboose private diagnostic, no public ICD gate bypass.
executable(
    'caboose_gfxstream_encoder_probe',
    'encoder_probe.cpp',
    objects: lib_vulkan_gfxstream.extract_all_objects(recursive: false),
    cpp_args: gfxstream_guest_args,
    include_directories: [
        inc_vulkan_headers, inc_guest_iostream, inc_vulkan_enc,
        inc_goldfish_address_space, inc_include, inc_src, inc_aemu,
        inc_platform_virtgpu, inc_connection_manager,
    ],
    link_with: [libvulkan_wsi, libplatform_virtgpu, libconnection_manager, libaemu],
    dependencies: gfxstream_deps,
    link_args: [ld_args_gc_sections],
    install: false,
)
'''


def apply(root):
    target = Path(root) / 'src/gfxstream/guest/vulkan'
    meson = target / 'meson.build'
    data = meson.read_bytes()
    if hashlib.sha256(data).hexdigest() != EXPECTED:
        raise ValueError('unexpected Mesa Vulkan meson.build')
    dest = target / 'encoder_probe.cpp'
    if dest.exists():
        raise FileExistsError(dest)
    shutil.copyfile(HERE / 'encoder_probe.cpp', dest)
    meson.write_bytes(data + TARGET.encode())


if __name__ == '__main__':
    if len(sys.argv) != 2:
        raise SystemExit('usage: prepare_probe.py PREPARED_MESA_TREE')
    apply(sys.argv[1])
