#!/usr/bin/env python3
"""Turn a pinned Mesa checkout into the Caboose gfxstream driver source tree.

Applies the patch series in patches/ to upstream files and installs the
Caboose-owned sources (the socket transport, the virtual WSI client and the
bounded-memory headers) at the paths the patches include them from.

usage: prepare.py MESA_CHECKOUT
"""
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import sys

DRIVER = Path(__file__).resolve().parent
GFXSTREAM = DRIVER.parent
MESA_REVISION = '541c56aa3fd24027ed46ae350287d21dcd56c901'

# Caboose-owned source -> its path in the Mesa tree.
OWNED = {
    'SocketStream.h': 'src/gfxstream/guest/connection-manager/SocketStream.h',
    'SocketStream.cpp': 'src/gfxstream/guest/connection-manager/SocketStream.cpp',
    'virtual-wsi/client.h': 'src/gfxstream/guest/vulkan/caboose-wsi/client.h',
    'virtual-wsi/client.cpp': 'src/gfxstream/guest/vulkan/caboose-wsi/client.cpp',
    'virtual-wsi/wire.h': 'src/gfxstream/guest/vulkan/caboose-wsi/wire.h',
    'virtual-wsi/mesa_surface.inc': 'src/gfxstream/guest/vulkan/caboose-wsi/mesa_surface.inc',
    'virtual-wsi/mesa_swapchain.inc': 'src/gfxstream/guest/vulkan/caboose-wsi/mesa_swapchain.inc',
    **{f'bounded-memory/{name}': f'src/gfxstream/guest/vulkan_enc/caboose-bounded-memory/{name}'
       for name in ('async_allocation.h', 'cb_staging.h', 'completion_feed.h', 'deferred_replies.h',
                    'flush_packet.h', 'flush_shadow.h', 'flush_timing.h', 'ranges.h',
                    'requirements_cache.h', 'rpc_timing.h', 'static_query_cache.h')},
}


def patches():
    """The series in application order: NNNN-name.patch, numbered from 0001 without gaps."""
    series = sorted(DRIVER.glob('patches/*.patch'))
    for index, patch in enumerate(series, 1):
        if not patch.name.startswith(f'{index:04d}-'):
            raise ValueError(f'patch series is not contiguous at {patch.name}')
    return series


def patched_paths(patch):
    """Files a patch changes, from its git diff headers."""
    paths = []
    for line in patch.read_text().splitlines():
        if line.startswith('diff --git a/'):
            old, new = line[len('diff --git a/'):].split(' b/')
            if old != new:
                raise ValueError(f'{patch.name}: renames are not supported')
            paths.append(new)
    return paths


def git(root, *args, **kwargs):
    return subprocess.run(['git', '-C', str(root), *args], check=True, text=True,
                          capture_output=True, **kwargs).stdout


def manifest():
    """SHA-256 of every input that determines the prepared tree."""
    inputs = {f'patches/{p.name}': p for p in patches()}
    inputs.update({source: GFXSTREAM / source for source in OWNED})
    return {'mesa': MESA_REVISION,
            'inputs': {name: hashlib.sha256(path.read_bytes()).hexdigest()
                       for name, path in sorted(inputs.items())}}


def prepare(root):
    root = Path(root)
    if git(root, 'rev-parse', 'HEAD').strip() != MESA_REVISION:
        raise ValueError(f'{root} is not Mesa {MESA_REVISION}')
    if git(root, 'status', '--porcelain', '--untracked-files=all', '--', 'src/gfxstream'):
        raise ValueError(f'{root}: src/gfxstream is not a clean checkout')
    owned = set(OWNED.values())
    for patch in patches():
        overlap = owned.intersection(patched_paths(patch))
        if overlap:
            raise ValueError(f'{patch.name} changes Caboose-owned files: {sorted(overlap)}')
        # Exact application: no fuzz, no offsets beyond git's own, no whitespace fixes.
        git(root, 'apply', '--check', str(patch))
        git(root, 'apply', str(patch))
    for source, destination in OWNED.items():
        target = root / destination
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(GFXSTREAM / source, target)
    (root / 'src/gfxstream/caboose-driver.json').write_text(json.dumps(manifest(), indent=2) + '\n')


if __name__ == '__main__':
    if len(sys.argv) != 2:
        raise SystemExit('usage: prepare.py MESA_CHECKOUT')
    prepare(sys.argv[1])
