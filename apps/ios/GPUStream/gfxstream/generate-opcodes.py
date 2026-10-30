#!/usr/bin/env python3
"""Generate the pinned decoder-case value set; never downloads sources."""
import hashlib
import pathlib
import re
import sys

if len(sys.argv) != 2:
    raise SystemExit('usage: generate-opcodes.py PINNED_GFXSTREAM_ROOT')
root = pathlib.Path(sys.argv[1])
files = {
    'host/vulkan/cereal/common/goldfish_vk_marshaling.h': '2174da9a4aaf50d228c36537c6b6fc3c66ccec8e8ce1c6c761e225da1488a302',
    'host/vulkan/vk_decoder.cpp': '5d1e1b5e5603e4f05aa72f11002beb37e3e258ae5f67f66b176d3848574a56a7',
}
text = []
for path, expected in files.items():
    data = (root / path).read_bytes()
    if hashlib.sha256(data).hexdigest() != expected:
        raise SystemExit('source hash mismatch: ' + path)
    text.append(data.decode())
defs = dict(re.findall(r'^#define\s+(OP_vk\w+)\s+(\d+)\b', text[0], re.M))
names = set(re.findall(r'\bcase\s+(OP_vk\w+)\s*:', text[1]))
if not names or names - defs.keys():
    raise SystemExit('decoder cases missing numeric definitions')
values = sorted(int(defs[name]) for name in names)
if len(values) != len(set(values)):
    raise SystemExit('duplicate decoder opcode values')
out = pathlib.Path(__file__).with_name('decoder-opcodes.inc')
out.write_text('// Generated from pinned gfxstream decoder cases; see generate-opcodes.py.\n' +
               ''.join('    ' + str(value) + 'u,\n' for value in values))
print('generated', len(values), 'decoder opcode values')
