#!/usr/bin/env python3
"""Create a private Vulkan ICD manifest for a verified, existing library."""
import hashlib
import json
import os
from pathlib import Path
import tempfile
import sys


def write_manifest(library, expected, output, api_version):
    library = Path(library).resolve(strict=True)
    if not library.is_file() or len(expected) != 64:
        raise ValueError('expected a library and SHA-256')
    with library.open('rb') as source:
        digest = hashlib.sha256()
        for block in iter(lambda: source.read(1024 * 1024), b''):
            digest.update(block)
        if digest.hexdigest() != expected.lower():
            raise ValueError('library SHA-256 mismatch')
    manifest = {'file_format_version': '1.0.1', 'ICD': {
        'library_path': str(library), 'api_version': api_version, 'library_arch': '64'}}
    output = Path(output)
    if output.exists():
        raise FileExistsError(output)
    fd, name = tempfile.mkstemp(prefix='.icd-', dir=output.parent)
    try:
        with os.fdopen(fd, 'w', encoding='utf-8') as file:
            json.dump(manifest, file, indent=2)
            file.write('\n')
        # Do not overwrite a concurrent manifest.
        os.link(name, output)
    finally:
        os.unlink(name)


if __name__ == '__main__':
    if len(sys.argv) != 5:
        raise SystemExit('usage: make_manifest.py LIBRARY SHA256 OUTPUT API_VERSION')
    write_manifest(*sys.argv[1:])
