#!/usr/bin/env python3
"""Two-TU incremental check against the retained, verified 873 WSI link.

Run inside the pinned compiler image with /work and /previous read-only,
/slice immutable transformed sources, and only /out writable.
"""
import hashlib
import json
from pathlib import Path
import shlex
import subprocess
import sys


def digest(path): return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    source, previous, output = Path('/slice'), Path('/previous'), Path('/out')
    baseline = json.loads((source / 'baseline.json').read_text())
    expected = {
        'libvulkan_gfxstream.so': '873d6bba0ac8054adc4f5f6be98c9361269cac971a1d441375e8934b54bd13e1',
        'gfxstream_vk_device.cpp.o': '1c349be209764efb6e02ba6ed27135dea8de1ec82354fff8c2a3aa5dd8b91210',
        'client.cpp.o': 'bc50035d6d170e3e1bea75331b709bdb0d999848cd2ad0e4ec937e828ae5f938',
        'libconnection_manager.a': '999561d9d90a67cdb57f8526b3fc535a513c9c3df3a8bf95ebc7524367af5e9d',
    }
    for name, sha in expected.items():
        if digest(previous / name) != sha: raise ValueError('retained 873 input changed: ' + name)
    # Original link recorded all direct inputs and thin-archive members.
    for name, sha in baseline['input_sha256'].items():
        if digest(Path(name)) != sha: raise ValueError('retained baseline input changed: ' + name)
    database = Path('/work/build-private/compile_commands.json')
    if digest(database) != baseline['database_sha256']: raise ValueError('compile database changed')
    entries = json.loads(database.read_text())
    commands, replacements = [], {}
    for name in ('VkEncoder.cpp', 'ResourceTracker.cpp'):
        matches = [e for e in entries if e['file'].endswith('/' + name)]
        if len(matches) != 1 or matches[0]['directory'] != '/work/build-private':
            raise ValueError('ambiguous compile command')
        entry = matches[0]; original = entry.get('arguments') or shlex.split(entry['command'])
        args, skip, found = [], False, 0
        for arg in original:
            if skip: skip=False; continue
            if arg in ('-o', '-MF', '-MT', '-MQ'): skip=True; continue
            if arg in ('-MD', '-MMD', '-MP', '-c'): continue
            if arg == entry['file']: found+=1; continue
            args.append(arg)
        if found != 1 or args[0] != 'c++': raise ValueError('unexpected compiler command')
        args += ['-I/slice', '-DCABOOSE_GFXSTREAM_PRIVATE_LIVE',
                 '-DCABOOSE_GFXSTREAM_PRIVATE_INDEXED_WSI', '-c', str(source / name),
                 '-o', str(output / (name + '.o'))]
        commands.append(args)
        replacements[entry['output']] = str(output / (name + '.o'))
    link = baseline['commands'][-1]
    if link.count('/out/link/libvulkan_gfxstream.so') != 1: raise ValueError('unexpected target')
    linked=[]
    for arg in link:
        if arg == '/out/link/libvulkan_gfxstream.so': linked.append('/out/libvulkan_gfxstream.so')
        elif arg in replacements: linked.append(replacements.pop(arg))
        elif arg.startswith('/out/link/'): linked.append(str(previous / Path(arg).name))
        else: linked.append(arg)
    if replacements: raise ValueError('missing object replacement')
    commands.append(linked)
    manifest = {'cwd':'/work/build-private', 'commands':commands,
                'previous_sha256':expected, 'retained_input_sha256':baseline['input_sha256'],
                'source_sha256':{str(p.relative_to(source)):digest(p) for p in sorted(source.rglob('*')) if p.is_file()}}
    print(json.dumps(manifest,indent=2),flush=True)
    if sys.argv[1:] == ['--plan']: return
    if sys.argv[1:]: raise ValueError('unknown argument')
    if any(output.iterdir()): raise ValueError('output must be empty')
    (output/'manifest.json').write_text(json.dumps(manifest,indent=2)+'\n')
    for command in commands: subprocess.run(command,cwd='/work/build-private',check=True,timeout=180)
    # These references are absent from the old object: they establish compiled
    # indexed staging, not merely successful linking of the delegated old path.
    symbols=subprocess.check_output(['nm','-C',str(output/'VkEncoder.cpp.o')],text=True)
    for required in ('caboose::memory::processBudget','ResourceTracker::cabooseMappedRange',
                     'VkEncoder::cabooseFlushMemoryChunk','VkEncoder::cabooseInvalidateMemoryChunk'):
        if required not in symbols: raise ValueError('missing compiled indexed branch: '+required)
    (output/'encoder-symbols.txt').write_text(symbols)
    result=output/'libvulkan_gfxstream.so'
    (output/'result.json').write_text(json.dumps({'sha256':digest(result),'bytes':result.stat().st_size,
        'compile_link_exit':0,'indexed_symbols_checked':True,'runtime_tested':False},indent=2)+'\n')


if __name__=='__main__': main()
