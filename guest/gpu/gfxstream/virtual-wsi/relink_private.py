#!/usr/bin/env python3
"""Replay an isolated four-TU private ICD link from identified retained inputs.

The source slice and retained Mesa/build/sysroot are read-only. Only OUT is
writable. --plan prints exact argv without compiling. This is an incremental
candidate link, not a claim that retained objects match uncommitted source.
"""
import hashlib
import json
from pathlib import Path
import shlex
import subprocess
import sys


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def plan(database, link_file, source, output):
    entries = json.loads(database.read_text())
    commands = []
    for filename in ('gfxstream_vk_device.cpp', 'SocketStream.cpp',
                     'GfxStreamConnectionManager.cpp', 'client.cpp'):
        original_name = 'gfxstream_vk_device.cpp' if filename == 'client.cpp' else filename
        selected = [e for e in entries if e['file'].endswith('/' + original_name)]
        if len(selected) != 1 or selected[0]['directory'] != '/work/build-private':
            raise ValueError('unexpected retained compilation entry')
        entry = selected[0]
        original = entry.get('arguments') or shlex.split(entry['command'])
        if original[0] != 'c++':
            raise ValueError('unexpected compiler')
        args, skip, replacements = [], False, 0
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
                replacements += 1
                continue
            args.append(arg)
        if replacements != 1:
            raise ValueError('missing original source')
        args += ['-I' + str(source), '-I' + str(source / 'caboose-wsi'),
                 '-DCABOOSE_GFXSTREAM_PRIVATE_LIVE', '-DCABOOSE_GFXSTREAM_PRIVATE_INDEXED_WSI']
        if original_name == 'gfxstream_vk_device.cpp':
            args += ['-DGFXSTREAM_VK_WAYLAND', '-DVK_USE_PLATFORM_WAYLAND_KHR']
        input_file = source / ('caboose-wsi/client.cpp' if filename == 'client.cpp' else filename)
        args += ['-c', str(input_file), '-o', str(output / (filename + '.o'))]
        commands.append(args)
    archive = 'src/gfxstream/guest/connection-manager/libconnection_manager.a'
    # Rebuild the five-member archive with unchanged members read-only. The
    # retained archive is thin, so copying it to a different directory is unsafe.
    members = ['GfxStreamConnection.cpp', 'GfxStreamConnectionManager.cpp',
               'SocketStream.cpp', 'VirtioGpuPipeStream.cpp', 'QemuPipeStreamStub.cpp']
    commands.append(['gcc-ar', 'csrD', str(output / 'libconnection_manager.a')] + [
        str(output / (name + '.o')) if name in members[1:3]
        else archive + '.p/' + name + '.o' for name in members])
    link = json.loads(link_file.read_text())
    target = 'src/gfxstream/guest/vulkan/libvulkan_gfxstream.so'
    device = target + '.p/gfxstream_vk_device.cpp.o'
    for anchor in (target, device, archive):
        if link.count(anchor) != 1:
            raise ValueError('unexpected linker anchor: ' + anchor)
    link = [str(output / 'libvulkan_gfxstream.so') if a == target else
            str(output / 'gfxstream_vk_device.cpp.o') if a == device else
            str(output / 'libconnection_manager.a') if a == archive else a for a in link]
    link += [str(output / 'client.cpp.o'), '-lwayland-client']
    commands.append(link)
    return commands


def main():
    if len(sys.argv) not in (5, 6) or (len(sys.argv) == 6 and sys.argv[5] != '--plan'):
        raise SystemExit('usage: relink_private.py DATABASE LINK_ARGV_JSON SOURCE OUT [--plan]')
    database, link_file, source, output = map(Path, sys.argv[1:5])
    # Quoted includes search the translation unit's own directory first. Both
    # rebuilt socket users must see the same canonical class layout as the WSI.
    if digest(source / 'SocketStream.h') != digest(source / 'caboose-wsi/SocketStream.h'):
        raise ValueError('canonical socket headers differ')
    commands = plan(database, link_file, source, output)
    manifest = {'cwd': '/work/build-private', 'commands': commands,
                'database_sha256': digest(database), 'link_argv_sha256': digest(link_file),
                'source_sha256': {str(p.relative_to(source)): digest(p)
                                  for p in sorted(source.rglob('*')) if p.is_file()}}
    print(json.dumps(manifest, indent=2), flush=True)
    if len(sys.argv) == 6:
        return
    if output.exists() and any(output.iterdir()):
        raise ValueError('output directory must be empty')
    output.mkdir(exist_ok=True)
    inputs = {}
    for command in commands:
        for arg in command[1:]:
            path = Path('/work/build-private') / arg
            if not arg.startswith('-') and path.is_file() and not path.is_relative_to(output):
                inputs[str(path)] = digest(path)
                if path.suffix == '.a':
                    # Hash thin members too; the archive hash alone is insufficient.
                    for member in subprocess.check_output(['ar', 't', str(path)], text=True).splitlines():
                        member_path = Path(member)
                        if not member_path.is_absolute():
                            member_path = path.parent / member_path
                        if member_path.is_file():
                            inputs[str(member_path)] = digest(member_path)
    manifest['input_sha256'] = inputs
    (output / 'manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')
    for command in commands:
        subprocess.run(command, cwd='/work/build-private', check=True, timeout=180)
    result = output / 'libvulkan_gfxstream.so'
    (output / 'result.json').write_text(json.dumps({'sha256': digest(result),
        'size': result.stat().st_size, 'compile_and_link_exit': 0}, indent=2) + '\n')


if __name__ == '__main__':
    main()
