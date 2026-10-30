#!/usr/bin/env python3
"""Replay one retained Mesa compiler command as a bounded, output-free syntax check."""
import hashlib
import json
from pathlib import Path
import shlex
import subprocess
import sys

if len(sys.argv) not in (3,4) or (len(sys.argv)==4 and sys.argv[3]!='--indexed'):
    raise SystemExit('usage: check_mesa_surface.py COMPILE_COMMANDS SOURCE [--indexed]')
database, source = map(Path, sys.argv[1:3])
entries = [entry for entry in json.loads(database.read_text())
           if entry['file'].endswith('/vulkan/gfxstream_vk_device.cpp')]
if len(entries) != 1:
    raise SystemExit('expected exactly one Mesa device compilation entry')
entry = entries[0]
original = entry.get('arguments') or shlex.split(entry['command'])
if original[0] not in ('c++', 'g++', 'clang++'):
    raise SystemExit('unexpected compiler or wrapper')
args = []
skip = False
replaced = 0
for arg in original:
    if skip:
        skip = False
        continue
    if arg in ('-o', '-MF', '-MT', '-MQ'):
        skip = True
        continue
    if arg in ('-MD', '-MMD', '-MP', '-c'):
        continue
    if arg == entry['file']:
        args.append(str(source.resolve()))
        replaced += 1
    else:
        args.append(arg)
if replaced != 1:
    raise SystemExit('expected exactly one source argument')
args += ['-fsyntax-only', '-I' + str(source.resolve().parent),
         '-DGFXSTREAM_VK_WAYLAND', '-DVK_USE_PLATFORM_WAYLAND_KHR',
         '-DCABOOSE_GFXSTREAM_PRIVATE_LIVE']
if len(sys.argv)==4:
    args.append('-DCABOOSE_GFXSTREAM_PRIVATE_INDEXED_WSI')
print(json.dumps({'compiler_argv': args, 'cwd': entry['directory'],
                  'source_sha256': hashlib.sha256(source.read_bytes()).hexdigest()}, indent=2), flush=True)
subprocess.run(args, cwd=entry['directory'], check=True, timeout=60)
