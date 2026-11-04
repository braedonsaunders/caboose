#!/usr/bin/env python3
"""Turn a pinned Mesa checkout into the Caboose gfxstream driver source tree.

Applies the patch series in patches/ to upstream files and installs the
Caboose-owned sources (the socket transport, the virtual WSI client, the
bounded-memory headers, the dma-buf headers and the video import) at the paths the patches include them from.

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
    'virtual-wsi/mesa_pending.inc': 'src/gfxstream/guest/vulkan/caboose-wsi/mesa_pending.inc',
    'virtual-wsi/mesa_swapchain.inc': 'src/gfxstream/guest/vulkan/caboose-wsi/mesa_swapchain.inc',
    **{f'bounded-memory/{name}': f'src/gfxstream/guest/vulkan_enc/caboose-bounded-memory/{name}'
       for name in ('async_allocation.h', 'cb_staging.h', 'completion_feed.h', 'deferred_replies.h',
                    'flush_packet.h', 'flush_shadow.h', 'flush_timing.h', 'ranges.h',
                    'requirements_cache.h', 'rpc_timing.h', 'static_query_cache.h', 'capability_chains.h',
                    'query_results.h', 'handles.h', 'upload_cache.h', 'write_watch.h', 'poll_stall.h',
                    'deferred_destroys.h', 'presentation_retirement.h', 'event_status.h', 'memory_traffic.h',
                    'lost_memory.h', 'lock_order.h', 'guest_set_ids.h')},
    **{f'dmabuf/{name}': f'src/gfxstream/guest/vulkan_enc/caboose-dmabuf/{name}'
       for name in ('dmabuf.h', 'registration.h', 'remote_images.h', 'sync_file.h')},
    **{f'media/{name}': f'src/gfxstream/guest/vulkan_enc/caboose-media/{name}'
       for name in ('gpu_media.h', 'media_import.h', 'media_import.inc')},
    'shader-cache/shader_cache.h': 'src/gfxstream/guest/vulkan_enc/caboose-shader-cache/shader_cache.h',
    'feature-emulation/feature_emulation.h':
        'src/gfxstream/guest/vulkan_enc/caboose-features/feature_emulation.h',
    'feature-emulation/d3d11_emulation.h':
        'src/gfxstream/guest/vulkan_enc/caboose-features/d3d11_emulation.h',
    'feature-emulation/d3d11_tracker.inc':
        'src/gfxstream/guest/vulkan_enc/caboose-features/d3d11_tracker.inc',
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
    inputs = manifest()
    source_identity = hashlib.sha256(json.dumps(inputs, sort_keys=True).encode()).hexdigest()
    (root / 'src/gfxstream/guest/vulkan_enc/caboose-bounded-memory/source_identity.h').write_text(
        '#pragma once\n#define CABOOSE_DRIVER_SOURCE_ID "' + source_identity + '"\n')
    (root / 'src/gfxstream/caboose-driver.json').write_text(json.dumps(inputs, indent=2) + '\n')


if __name__ == '__main__':
    if len(sys.argv) != 2:
        raise SystemExit('usage: prepare.py MESA_CHECKOUT')
    prepare(sys.argv[1])
