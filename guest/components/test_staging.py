"""Every file the components manifest lists is staged by each builder that runs the installer.

    python3 guest/components/test_staging.py

The installer runs from a copy of guest/ laid out as the manifest names it: the host image
keeps one at /app/guest for updating computers, the container image stages one at
/tmp/bundle, and the VM image copies its /builder directories to /tmp. A file missing from
any of them breaks that builder's install or a later component update.
"""
import json
import posixpath
import re
import shlex
import unittest
from pathlib import Path

GUEST = Path(__file__).resolve().parent.parent
REPO = GUEST.parent
MANIFEST = json.loads((GUEST / 'components/manifest.json').read_text())


def copies(dockerfile):
    """(sources, destination) of each COPY that reads the build context."""
    text = re.sub(r'\\\n', ' ', dockerfile.read_text())
    found = []
    for line in text.splitlines():
        words = shlex.split(line.strip(), comments=True) if line.strip().startswith('COPY') else []
        if not words or any(word.startswith('--from') for word in words):
            continue
        args = [word for word in words[1:] if not word.startswith('--')]
        found.append((args[:-1], args[-1]))
    return found


def staged(dockerfile, source_prefix, destination_prefix):
    """Guest-relative paths a Dockerfile stages under destination_prefix, mirroring the
    guest tree: a directory copied to its own name, or files copied to their directory."""
    paths = set()
    for sources, destination in copies(dockerfile):
        for source in sources:
            if not source.startswith(source_prefix):
                continue
            relative = source[len(source_prefix):].rstrip('/')
            if destination.endswith('/') and posixpath.normpath(destination) == posixpath.normpath(
                    destination_prefix + posixpath.dirname(relative)) and (REPO / dockerfile_context(dockerfile) / source).is_file():
                paths.add(relative)
            elif posixpath.normpath(destination) == posixpath.normpath(destination_prefix + relative):
                paths.add(relative + '/')
    return paths


def dockerfile_context(dockerfile):
    # apps/host/Dockerfile builds from the repository root; the guest images from guest/.
    return '.' if dockerfile == REPO / 'apps/host/Dockerfile' else 'guest'


def covered(name, paths):
    return name in paths or any(path.endswith('/') and name.startswith(path) for path in paths)


class Staging(unittest.TestCase):
    def assert_staged(self, label, paths):
        missing = [name for name in MANIFEST if not covered(name, paths)]
        self.assertEqual(missing, [], f'{label} does not stage these manifest files')

    def test_host_image(self):
        self.assert_staged('apps/host/Dockerfile', staged(REPO / 'apps/host/Dockerfile', 'guest/', './guest/'))

    def test_container_image(self):
        self.assert_staged('guest/container/Dockerfile', staged(GUEST / 'container/Dockerfile', '', '/tmp/bundle/'))

    def test_vm_image(self):
        builder = staged(GUEST / 'image/Dockerfile', '', '/builder/')
        script = (GUEST / 'image/build-inside.sh').read_text()
        moved = set(re.findall(r'cp -r /builder/([a-z0-9-]+) "\$work/root/tmp/\1"', script))
        # build-inside.sh moves whole /builder directories to /tmp, where the installer runs.
        paths = {path for path in builder if path.split('/')[0] in moved}
        self.assert_staged('guest/image/Dockerfile with build-inside.sh', paths)
        removed = set(re.findall(r'"\$work/root/tmp/([a-z0-9-]+)"', script.split('rm -rf "$work/root/tmp/components"')[1].split('\n')[0]))
        self.assertEqual(moved - {'components'} - removed, set(), 'build-inside.sh leaves these in the image /tmp')


if __name__ == '__main__':
    unittest.main()
