#!/usr/bin/env python3
"""Execute the WSI wire expressions against pinned gfxstream handle mappings.

Run in the retained Mesa build directory. No loader, decoder, socket or GPU is
used. SOURCE contains mesa_*.inc/wire.h; OUT must be a new writable directory.
The fixture uses real Resources.h structures and compiles real Resources.cpp.
"""
import json
from pathlib import Path
import re
import shlex
import subprocess
import sys


def expressions(source):
    surface = (source / 'mesa_surface.inc').read_text()
    swap = (source / 'mesa_swapchain.inc').read_text()
    cases = [
        ('instance', 'VkInstance', 'owner', surface, r'surface->boxedInstance=(.*?);'),
        ('physical', 'VkPhysicalDevice', 'device', surface,
         r'surface\.client\.query\(\+\+surface.query,\s*(.*?),deadline\(\)\)'),
        ('device', 'VkDevice', 'device', swap,
         r'put64\(request,(.*?)\); put64\(request,old\)'),
        ('image', 'VkImage', None, swap, r'images\.push_back\((.*?)\);'),
        ('acquire_semaphore', 'VkSemaphore', 'value', swap, r'(?m)^            boxedSemaphore=(.*?);'),
        ('acquire_fence', 'VkFence', 'value', swap, r'(?m)^            boxedFence=(.*?);'),
        ('present_wait', 'VkSemaphore', 'value', swap, r'waits\.push_back\((.*?)\);'),
        ('queue', 'VkQueue', 'queue', swap,
         r'presentIndexed\(swap->native,serial,\s*(.*?),index,swap->family'),
    ]
    result = []
    for name, kind, owner, text, pattern in cases:
        found = re.findall(pattern, text)
        if len(found) != 1:
            raise ValueError('missing or ambiguous wire conversion: ' + name)
        result.append((name, kind, owner, found[0]))
    return result


def fixture(source):
    code = ['#include "Resources.h"', '#include "wire.h"', '#include <cstdio>',
            'int main() { unsigned failures=0;']
    for n, (name, kind, owner, expression) in enumerate(expressions(source), 1):
        code += ['{', f'goldfish_{kind} storage{{}};',
                 f'const uint64_t expected=0xf123456789ab0000ULL+{n};',
                 'storage.underlying=expected;',
                 f'{kind} handle=reinterpret_cast<{kind}>(&storage);',
                 'if (uint64_t(reinterpret_cast<uintptr_t>(handle))==expected) return 2;']
        if owner:
            code += [f'struct Holder {{ {kind} internal_object; }} holder{{handle}};',
                     f'auto* {owner}=&holder;']
        else:
            code += [f'struct Holder {{ {kind} image; }} image{{handle}};']
        code += [f'const uint64_t actual={expression};',
                 'caboose::wsi::Bytes bytes; caboose::wsi::put64(bytes,actual);',
                 'bool ok=actual==expected && bytes.size()==8;',
                 'for (unsigned i=0;i<8;++i) ok &= bytes[i]==uint8_t(expected>>(8*i));',
                 f'if (!ok) {{ std::fprintf(stderr,"{name}: guest address escaped into wire ID\\n"); ++failures; }}',
                 f'if (get_host_u64_{kind}(VK_NULL_HANDLE)!=0) return 2;', '}']
    code += ['if (failures) return 1;',
             'std::puts("PASS: 8 WSI wire conversions, 7 handle types, null and LE checks"); return 0; }']
    return '\n'.join(code) + '\n'


def main():
    database, source, output = map(Path, sys.argv[1:4])
    expect_reject = len(sys.argv) == 5 and sys.argv[4] == '--expect-reject'
    if len(sys.argv) not in (4, 5) or (len(sys.argv) == 5 and not expect_reject):
        raise SystemExit('usage: check_host_handles.py DATABASE SOURCE OUT [--expect-reject]')
    output.mkdir(exist_ok=False)
    entries = [e for e in json.loads(database.read_text()) if e['file'].endswith('/Resources.cpp')]
    if len(entries) != 1:
        raise ValueError('expected one retained Resources.cpp command')
    entry = entries[0]
    original = entry.get('arguments') or shlex.split(entry['command'])
    args, skip = [], False
    for arg in original:
        if skip:
            skip = False
            continue
        if arg in ('-o', '-MF', '-MT', '-MQ'):
            skip = True
            continue
        if arg in ('-MD', '-MMD', '-MP', '-c') or arg == entry['file']:
            continue
        args.append(arg)
    args += ['-ffunction-sections', '-fdata-sections', '-UNDEBUG']
    generated = output / 'host_handles.cpp'
    generated.write_text(fixture(source))
    commands = [
        args + ['-c', entry['file'], '-o', str(output / 'Resources.o')],
        args + ['-I' + str(source), '-I' + str(Path(entry['file']).parent),
                '-c', str(generated), '-o', str(output / 'test.o')],
        ['c++', '-Wl,--gc-sections', str(output / 'Resources.o'), str(output / 'test.o'),
         '-o', str(output / 'check')],
    ]
    (output / 'commands.json').write_text(json.dumps(commands, indent=2)+'\n')
    for command in commands:
        subprocess.run(command, cwd=entry['directory'], check=True, timeout=30)
    result = subprocess.run([str(output / 'check')], timeout=10)
    if result.returncode != (1 if expect_reject else 0):
        raise SystemExit('unexpected handle-mapping fixture result: ' + str(result.returncode))
    if expect_reject:
        print('PASS: original pointer-cast source rejected by regression', flush=True)


if __name__ == '__main__':
    main()
