"""The packages: what debian/layout installs, that the host ships it, and what package.py builds.

    python3 -m unittest discover -s guest/computer-use/tests

The build checks need dpkg-deb and are skipped without it."""
import json
import re
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent.parent
MANIFEST = set(json.loads((HERE.parent / 'components/manifest.json').read_text()))
LAYOUT = [line.split() for line in (HERE / 'debian/layout').read_text().splitlines() if line.strip() and not line.startswith('#')]
FILES = {source: destination for package, kind, source, destination in LAYOUT if kind != 'link' and package == 'caboose-computer-use'}


class Layout(unittest.TestCase):
    def test_every_module_the_server_imports_is_packaged_beside_it(self):
        pending, seen = ['server/main.mjs'], set()
        while pending:
            source = pending.pop()
            if source in seen:
                continue
            seen.add(source)
            self.assertIn(source, FILES, f'{source} is not packaged')
            for module in re.findall(r"^import [^\n]*? from '\./([^']+)'", (HERE / source).read_text(), re.M):
                pending.append(f'server/{module}')
        self.assertEqual({FILES[s].rsplit('/', 1)[0] for s in seen}, {'/usr/lib/caboose/computer-use/server'})
        self.assertGreater(len(seen), 5)

    def test_every_helper_the_server_runs_is_packaged(self):
        for name in re.findall(r"helper\('([a-z_]+\.py)'\)", (HERE / 'server/seat.mjs').read_text()):
            self.assertEqual(FILES[f'helpers/{name}'], f'/usr/lib/caboose/computer-use/helpers/{name}')

    def test_the_host_ships_every_packaged_file_and_the_packaging(self):
        shipped = {f'computer-use/{source}' for source in FILES} | {'computer-use/package.py', 'computer-use/install.sh'} \
            | {f'computer-use/debian/{p.name}' for p in (HERE / 'debian').iterdir()}
        self.assertEqual(sorted(shipped - MANIFEST), [])
        self.assertEqual(sorted(f for f in MANIFEST if f.startswith('computer-use/') and f not in shipped), [])

    def test_files_live_in_system_paths_only(self):
        for package, kind, source, destination in LAYOUT:
            self.assertRegex(destination, r'^/(usr/(bin|lib|libexec|share)|etc|opt/caboose)/', destination)
            self.assertNotIn('/usr/local/', destination)


@unittest.skipUnless(shutil.which('dpkg-deb'), 'needs dpkg-deb')
class Build(unittest.TestCase):
    def build(self, directory):
        return subprocess.run(['python3', str(HERE / 'package.py'), directory], check=True, capture_output=True, text=True).stdout.split()

    def test_the_package_installs_its_layout_and_its_version_follows_its_contents(self):
        with tempfile.TemporaryDirectory() as one, tempfile.TemporaryDirectory() as two:
            [deb] = self.build(one)
            self.assertEqual(Path(deb).read_bytes(), Path(self.build(two)[0]).read_bytes(), 'not reproducible')
            listing = subprocess.run(['dpkg-deb', '-c', deb], check=True, capture_output=True, text=True).stdout
            for destination in FILES.values():
                self.assertIn(f'.{destination}', listing)
            self.assertIn('./usr/bin/caboose-computer-use -> ../lib/caboose/computer-use/server/main.mjs', listing)
            fields = subprocess.run(['dpkg-deb', '-f', deb, 'Version', 'Architecture', 'Depends'], check=True, capture_output=True, text=True).stdout
            self.assertRegex(fields, r'Version: 1\.0\.0\+[0-9a-f]{12}\n')
            self.assertIn('tesseract-ocr', fields)
            conffiles = subprocess.run(['dpkg-deb', '--info', deb, 'conffiles'], check=True, capture_output=True, text=True).stdout.split()
            self.assertEqual(conffiles, ['/etc/chromium.d/zz-caboose-agent', '/etc/chromium/native-messaging-hosts/com.caboose.webmcp.json'])


if __name__ == '__main__':
    unittest.main()
