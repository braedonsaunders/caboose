#!/usr/bin/env python3
"""Fetch only the three pinned headers needed for the socket syntax check."""
import hashlib
import json
from pathlib import Path
import sys
import urllib.request

if len(sys.argv) != 2:
    raise SystemExit('usage: fetch-audit-headers.py OUTPUT_DIRECTORY')
manifest = json.loads((Path(__file__).parent / 'source-hashes.json').read_text())
paths = (
    'host/iostream/include/gfxstream/host/iostream.h',
    'host/include/render-utils/stream.h',
    'common/logging/include/gfxstream/common/logging.h',
)
base = 'https://raw.githubusercontent.com/google/gfxstream/' + manifest['commit'] + '/'
for name in paths:
    with urllib.request.urlopen(base + name, timeout=30) as response:
        data = response.read(65537)
    if len(data) > 65536 or hashlib.sha256(data).hexdigest() != manifest['sha256'][name]:
        raise SystemExit('size or hash mismatch: ' + name)
    target = Path(sys.argv[1]) / name
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_bytes(data)
    print(name, len(data))
