#!/usr/bin/env python3
"""Hash exactly the files shipped to an existing computer, including their names."""
import hashlib
import json
import pathlib
import sys

root = pathlib.Path(sys.argv[1])
names = json.loads((root / 'components/manifest.json').read_text())
h = hashlib.sha256()
for name in names:
    h.update(name.encode() + b'\0')
    h.update((root / name).read_bytes())
    h.update(b'\0')
print(h.hexdigest())
