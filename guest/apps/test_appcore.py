"""appcore: manifests, URLs, desktop entries, bridge bounds and file operations.

    python3 -m unittest discover -s guest/apps -p 'test_*.py'
"""

import json
import os
import shutil
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import appcore as apps  # noqa: E402


class Home(unittest.TestCase):
    def setUp(self):
        self.root = os.path.realpath(tempfile.mkdtemp(prefix='caboose-apps-'))
        self.addCleanup(shutil.rmtree, self.root)
        self.home = os.path.join(self.root, 'home')
        os.makedirs(self.home)
        self.places = apps.Places(self.home)

    def app(self, ident='notes', manifest=None, files=None):
        directory = os.path.join(self.home, 'Apps', ident)
        os.makedirs(directory, exist_ok=True)
        if manifest is not None:
            with open(os.path.join(directory, 'app.json'), 'w', encoding='utf-8') as handle:
                handle.write(manifest if isinstance(manifest, str) else json.dumps(manifest))
        for name, data in (files or {'index.html': '<!doctype html><title>x</title>'}).items():
            path = os.path.join(directory, name)
            os.makedirs(os.path.dirname(path), exist_ok=True)
            with open(path, 'w', encoding='utf-8') as handle:
                handle.write(data)
        return directory


class Ids(unittest.TestCase):
    def test_ids(self):
        for good in ('a', 'notes', 'photo-sorter', 'x' * 48, 'a1'):
            self.assertEqual(apps.check_id(good), good)
        for bad in ('', '1app', 'App', 'a_b', 'a.b', 'x' * 49, '../x', 'a/b', None, 3):
            with self.assertRaises(apps.AppError):
                apps.check_id(bad)

    def test_application_id(self):
        self.assertEqual(apps.application_id('photo-sorter'), 'caboose.app.photo-sorter')


class Manifest(Home):
    def test_minimal_defaults(self):
        manifest, errors = apps.load_manifest(self.app(manifest={'name': 'Notes'}))
        self.assertEqual(errors, [])
        self.assertEqual(manifest['entry'], 'index.html')
        self.assertEqual(manifest['categories'], ['Utility'])
        self.assertEqual(manifest['capabilities'], [])
        self.assertEqual(manifest['window'], {'width': 1024, 'height': 720})
        self.assertIsNone(manifest['icon'])

    def test_full(self):
        directory = self.app(manifest={
            'name': ' Server Status ', 'description': 'Load at a glance', 'version': '1.2', 'entry': 'ui/main.html',
            'icon': 'icon.svg', 'categories': ['System', 'System'], 'capabilities': ['exec', 'notify'],
            'window': {'width': 900, 'height': 640, 'minWidth': 360, 'background': '#0F1115'},
        }, files={'ui/main.html': '<html></html>', 'icon.svg': '<svg/>'})
        manifest, errors = apps.load_manifest(directory)
        self.assertEqual(errors, [])
        self.assertEqual(manifest['name'], 'Server Status')
        self.assertEqual(manifest['categories'], ['System'])
        self.assertEqual(manifest['capabilities'], ['exec', 'notify'])
        self.assertEqual(manifest['window'], {'width': 900, 'height': 640, 'minWidth': 360, 'background': '#0f1115'})

    def test_every_problem_is_reported(self):
        directory = self.app(manifest={
            'nmae': 'typo', 'entry': '../x.html', 'icon': 'icon.gif', 'categories': ['Games'],
            'capabilities': ['root'], 'window': {'width': 10, 'height': True, 'colour': 1, 'background': 'red'},
        })
        manifest, errors = apps.load_manifest(directory)
        self.assertIsNone(manifest)
        text = '\n'.join(errors)
        for fragment in ('Unknown field "nmae"', 'name is required', 'entry must be a relative path',
                         'icon must end in', 'categories has unknown Games', 'capabilities has unknown root',
                         'window.width', 'window.height', 'Unknown window field "colour"', 'window.background'):
            self.assertIn(fragment, text)

    def test_missing_and_invalid_files(self):
        directory = self.app(files={})
        self.assertEqual(apps.load_manifest(directory)[1], ['app.json is missing'])
        self.app(manifest='{not json')
        self.assertIn('not valid JSON', apps.load_manifest(directory)[1][0])
        self.app(manifest='[]')
        self.assertEqual(apps.load_manifest(directory)[1], ['app.json must be a JSON object'])
        self.app(manifest=' ' * (apps.MANIFEST_LIMIT + 1))
        self.assertIn('at most', apps.load_manifest(directory)[1][0])

    def test_entry_must_exist(self):
        directory = self.app(manifest={'name': 'A', 'entry': 'main.html'})
        self.assertIn('entry "main.html" is not a file in the app directory', apps.load_manifest(directory)[1])

    def test_symlink_escapes_are_refused(self):
        outside = os.path.join(self.root, 'secret.html')
        with open(outside, 'w') as handle:
            handle.write('x')
        directory = self.app(manifest={'name': 'A', 'entry': 'link.html'})
        os.symlink(outside, os.path.join(directory, 'link.html'))
        self.assertIn('entry leaves the app directory through a symbolic link', apps.load_manifest(directory)[1])

    def test_manifest_symlink_is_not_followed(self):
        directory = self.app()
        target = os.path.join(self.root, 'app.json')
        with open(target, 'w') as handle:
            json.dump({'name': 'A'}, handle)
        os.symlink(target, os.path.join(directory, 'app.json'))
        self.assertIn('could not be read', apps.load_manifest(directory)[1][0])

    def test_control_characters(self):
        directory = self.app(manifest={'name': 'A\nB'})
        self.assertIn('name must not contain control characters', apps.load_manifest(directory)[1])


class Urls(Home):
    def setUp(self):
        super().setUp()
        self.dir = self.app(manifest={'name': 'A'}, files={
            'index.html': 'i', 'app.js': 'j', 'sub/index.html': 's', 'sub/page one.html': 'p', 'ui/main.html': 'm'})

    def path(self, uri, entry='index.html'):
        found = apps.resource_path(self.dir, 'notes', uri, entry)
        return None if found is None else os.path.relpath(found, self.dir)

    def test_resolves(self):
        self.assertEqual(self.path('caboose-app://notes/'), 'index.html')
        self.assertEqual(self.path('caboose-app://notes'), 'index.html')
        self.assertEqual(self.path('caboose-app://notes/', 'ui/main.html'), os.path.join('ui', 'main.html'))
        self.assertEqual(self.path('caboose-app://notes/app.js?v=2#x'), 'app.js')
        self.assertEqual(self.path('caboose-app://notes/sub/'), os.path.join('sub', 'index.html'))
        self.assertEqual(self.path('caboose-app://notes/sub'), os.path.join('sub', 'index.html'))
        self.assertEqual(self.path('caboose-app://notes/sub/page%20one.html'), os.path.join('sub', 'page one.html'))

    def test_refuses(self):
        for uri in ('caboose-app://other/app.js', 'https://notes/app.js', 'caboose-app://notes:1/app.js',
                    'caboose-app://u@notes/app.js', 'caboose-app://notes/../x', 'caboose-app://notes/%2e%2e/x',
                    'caboose-app://notes/sub%2f..%2fapp.js', 'caboose-app://notes/a%00.js', 'caboose-app://notes/missing.js',
                    'caboose-app://notes//app.js', 'caboose-app://notes/%ff.js', 'caboose-app://notes/sub/./index.html',
                    'caboose-app://notes/a%5c..%5capp.js'):
            self.assertIsNone(self.path(uri), uri)

    def test_symlink_out_is_refused(self):
        outside = os.path.join(self.root, 'secret.txt')
        with open(outside, 'w') as handle:
            handle.write('x')
        os.symlink(outside, os.path.join(self.dir, 'leak.txt'))
        os.symlink(self.root, os.path.join(self.dir, 'up'))
        self.assertIsNone(self.path('caboose-app://notes/leak.txt'))
        self.assertIsNone(self.path('caboose-app://notes/up/secret.txt'))
        os.symlink(os.path.join(self.dir, 'app.js'), os.path.join(self.dir, 'alias.js'))
        self.assertEqual(self.path('caboose-app://notes/alias.js'), 'app.js')

    def test_app_url_and_matching(self):
        self.assertEqual(apps.app_url('notes'), 'caboose-app://notes/')
        self.assertTrue(apps.is_app_url('caboose-app://notes/x', 'notes'))
        self.assertFalse(apps.is_app_url('caboose-app://notes2/x', 'notes'))
        self.assertFalse(apps.is_app_url('https://notes/x', 'notes'))


class Content(unittest.TestCase):
    def test_types(self):
        self.assertEqual(apps.content_type('a.html'), 'text/html; charset=utf-8')
        self.assertEqual(apps.content_type('a.mjs'), 'text/javascript; charset=utf-8')
        self.assertEqual(apps.content_type('a.wasm'), 'application/wasm')
        self.assertEqual(apps.content_type('a.svg'), 'image/svg+xml; charset=utf-8')
        self.assertEqual(apps.content_type('a.unknownext'), 'application/octet-stream')
        self.assertEqual(apps.content_type('a.tar.gz'), 'application/octet-stream')

    def test_policy(self):
        directives = dict(part.strip().split(' ', 1) for part in apps.CSP.split(';'))
        self.assertEqual(directives['script-src'], "'self' caboose-app: 'wasm-unsafe-eval'")
        self.assertEqual(directives['worker-src'], "'self' caboose-app:")
        self.assertEqual(directives['frame-src'], "'self' caboose-app:")
        self.assertEqual(directives['object-src'], "'none'")
        self.assertNotIn('unsafe-inline', directives['default-src'])

    def test_page_problems(self):
        html = '\n'.join([
            '<!doctype html><script src="app.js"></script>',
            '<script type="module" src="./m.js"></script>',
            '<script type="application/json">{"data": 1}</script>',
            '<!-- <script>commented()</script> -->',
            '<script>',
            '  inline()',
            '</script>',
            '<button onclick="go()">Go</button>',
            '<a href="javascript:void(0)">x</a>',
            '<script type="module">import x from "./x.js"</script>',
            '<div data-src="x" data-onclick="y">fine</div><script></script>',
        ])
        self.assertEqual(apps.page_problems('index.html', html), [
            'index.html line 5: an inline <script> does not run; move it into a .js file in the app and load it with <script src="...">',
            'index.html line 10: an inline <script> does not run; move it into a .js file in the app and load it with <script src="...">',
            'index.html line 8: event handler attributes (onclick="...") do not run; use addEventListener in a .js file',
            'index.html line 9: javascript: URLs do not run; use addEventListener in a .js file',
        ])

    def test_pages_are_checked_at_publish(self):
        with tempfile.TemporaryDirectory() as home:
            directory = os.path.join(home, 'Apps', 'x')
            os.makedirs(os.path.join(directory, 'sub'))
            with open(os.path.join(directory, 'app.json'), 'w') as handle:
                json.dump({'name': 'X'}, handle)
            with open(os.path.join(directory, 'index.html'), 'w') as handle:
                handle.write('<script src="a.js"></script>')
            with open(os.path.join(directory, 'sub', 'p.htm'), 'w') as handle:
                handle.write('<body onload="x()">')
            result = apps.check(apps.Places(home), 'x')
            self.assertFalse(result['ok'])
            self.assertNotIn('manifest', result)
            self.assertEqual(len(result['errors']), 1)
            self.assertTrue(result['errors'][0].startswith(os.path.join('sub', 'p.htm') + ' line 1: event handler'))

    def test_csp_meta(self):
        meta = f'<meta http-equiv="Content-Security-Policy" content="{apps.CSP}">'.encode()
        self.assertEqual(apps.with_csp(b'<!DOCTYPE html><html><head lang="en"><title>x'),
                         b'<!DOCTYPE html><html><head lang="en">' + meta + b'<title>x')
        self.assertEqual(apps.with_csp(b'<!doctype html><body>x'), b'<!doctype html>' + meta + b'<body>x')
        self.assertEqual(apps.with_csp(b'<p>x'), meta + b'<p>x')
        self.assertNotIn(b'"', apps.CSP.encode())

    def test_external(self):
        for uri in ('https://example.com/a', 'http://example.com', 'mailto:a@b.c', 'tel:+15551234'):
            self.assertEqual(apps.external_url(uri), uri)
        for uri in ('javascript:alert(1)', 'data:text/html,x', 'file:///etc/passwd', 'https:///x',
                    'caboose-app://x/', 'https://e.com/\nx', 'ftp://e.com'):
            self.assertIsNone(apps.external_url(uri), uri)


class Publishing(Home):
    def test_desktop_entry(self):
        manifest, _ = apps.load_manifest(self.app(manifest={
            'name': 'Back\\slash\nx'.replace('\n', ' '), 'description': 'Line', 'version': '2', 'categories': ['Office', 'Utility']}))
        entry = apps.desktop_entry('notes', manifest, '/home/caboose/Apps/notes/icon.svg')
        self.assertEqual(entry, '\n'.join([
            '[Desktop Entry]', 'Type=Application', 'Name=Back\\\\slash x', 'Comment=Line',
            'Exec=/usr/local/bin/caboose-app run notes', 'Icon=/home/caboose/Apps/notes/icon.svg', 'Terminal=false',
            'Categories=Office;Utility;', 'StartupWMClass=caboose.app.notes', 'X-Caboose-App=notes',
            'X-Caboose-App-Version=2', '']))

    def test_publish_with_generated_icon(self):
        self.app(manifest={'name': 'Notes'})
        result = apps.publish(self.places, 'notes')
        self.assertTrue(result['ok'] and result['published'])
        entry = os.path.join(self.home, '.local/share/applications/caboose.app.notes.desktop')
        self.assertEqual(result['entry'], entry)
        with open(entry) as handle:
            self.assertIn(f'Icon={self.home}/.local/share/caboose/apps/notes/icon.svg', handle.read())
        with open(result['icon']) as handle:
            svg = handle.read()
        self.assertIn('>N</text>', svg)
        self.assertEqual(svg, apps.default_icon('notes', 'Notes'))
        self.assertEqual(apps.list_apps(self.places)[0]['published'], True)

    def test_publish_with_own_icon(self):
        self.app(manifest={'name': 'Notes', 'icon': 'art/icon.png'}, files={'index.html': 'x', 'art/icon.png': 'png'})
        self.assertEqual(apps.publish(self.places, 'notes')['icon'], os.path.join(self.home, 'Apps/notes/art/icon.png'))

    def test_invalid_is_not_published(self):
        self.app(manifest={'name': ''})
        result = apps.publish(self.places, 'notes')
        self.assertFalse(result['ok'])
        self.assertFalse(os.path.exists(self.places.entry('notes')))

    def test_missing_app(self):
        self.assertFalse(apps.check(self.places, 'nothing')['ok'])

    def test_list_and_remove(self):
        self.app('good', manifest={'name': 'Good', 'capabilities': ['files']})
        self.app('bad', manifest={})
        os.makedirs(os.path.join(self.home, 'Apps', 'Not An Id'))
        apps.publish(self.places, 'good')
        listed = {app['id']: app for app in apps.list_apps(self.places)}
        self.assertEqual(set(listed), {'good', 'bad'})
        self.assertEqual(listed['good']['capabilities'], ['files'])
        self.assertFalse(listed['bad']['ok'])
        self.assertEqual(apps.remove(self.places, 'good')['removed'], [self.places.entry('good')])
        self.assertTrue(os.path.isdir(self.places.app('good')))
        os.makedirs(self.places.files('good'))
        apps.remove(self.places, 'good', purge=True)
        self.assertFalse(os.path.exists(self.places.app('good')))
        self.assertFalse(os.path.exists(self.places.app_data('good')))

    def test_default_icon_letter(self):
        self.assertIn('>É</text>', apps.default_icon('x', '<écrire>'))
        self.assertIn('>Q</text>', apps.default_icon('q', '!!!'))


class Bounds(unittest.TestCase):
    def test_argv(self):
        self.assertEqual(apps.check_argv(['ls', '-l']), ['ls', '-l'])
        for bad in ([], 'ls', [''], ['ls', 3], ['a\0b'], ['x'] * 257, ['x' * (apps.MAX_ARG + 1)],
                    ['x' * apps.MAX_ARG] * 9):
            with self.assertRaises(apps.AppError):
                apps.check_argv(bad)

    def test_env(self):
        self.assertEqual(apps.check_env(None), {})
        self.assertEqual(apps.check_env({'A_1': 'x'}), {'A_1': 'x'})
        for bad in ({'1A': 'x'}, {'A=B': 'x'}, {'A': 1}, {'A': 'a\0'}, {f'K{i}': '' for i in range(65)}, ['A']):
            with self.assertRaises(apps.AppError):
                apps.check_env(bad)

    def test_timeout(self):
        self.assertEqual(apps.check_timeout(None), 60_000)
        self.assertEqual(apps.check_timeout(600_000), 600_000)
        for bad in (0, 600_001, 1.5, True, '10'):
            with self.assertRaises(apps.AppError):
                apps.check_timeout(bad)

    def test_capped(self):
        self.assertEqual(apps.capped([b'ab', b'cd'], 3), (b'abc', True))
        self.assertEqual(apps.capped([b'ab'], 3), (b'ab', False))


class Files(Home):
    def setUp(self):
        super().setUp()
        self.files = self.places.files('notes')
        os.makedirs(self.files)

    def split(self, path):
        return apps.split_path(path, self.home, self.files)

    def test_split(self):
        self.assertEqual(self.split('a/b.txt'), (self.files, ['a', 'b.txt']))
        self.assertEqual(self.split('./a//b'), (self.files, ['a', 'b']))
        self.assertEqual(self.split('.'), (self.files, []))
        self.assertEqual(self.split(f'{self.home}/Documents/x'), (self.home, ['Documents', 'x']))
        self.assertEqual(self.split('~/Documents/x'), (self.home, ['Documents', 'x']))
        self.assertEqual(self.split('~'), (self.home, []))
        for bad in ('../x', 'a/../../x', '/etc/passwd', f'{self.home}x/y', '~/../x', 'a\0', 7, 'x' * 5000):
            with self.assertRaises(apps.AppError):
                self.split(bad)

    def test_round_trip(self):
        root, parts = self.split('deep/er/data.bin')
        self.assertEqual(apps.write_file(root, parts, b'\x00\x01'), 2)
        self.assertEqual(apps.read_file(root, parts), b'\x00\x01')
        apps.write_file(root, parts, b'new')
        self.assertEqual(apps.read_file(root, parts), b'new')
        self.assertEqual([e['name'] for e in apps.list_dir(*self.split('deep/er'))], ['data.bin'])
        self.assertEqual(apps.stat_path(root, parts)['kind'], 'file')
        self.assertEqual(apps.stat_path(*self.split('deep'))['kind'], 'directory')
        apps.make_dir(*self.split('made/with/parents'))
        self.assertTrue(os.path.isdir(os.path.join(self.files, 'made/with/parents')))
        apps.remove_path(root, parts)
        self.assertFalse(os.path.exists(os.path.join(self.files, 'deep/er/data.bin')))
        with self.assertRaises(OSError):
            apps.remove_path(*self.split('made'))
        apps.remove_path(*self.split('made'), recursive=True)
        self.assertFalse(os.path.exists(os.path.join(self.files, 'made')))

    def test_root_is_not_a_file(self):
        with self.assertRaises(apps.AppError):
            apps.read_file(*self.split('.'))

    def test_limits(self):
        root, parts = self.split('big')
        apps.write_file(root, parts, b'x' * 10)
        with self.assertRaises(apps.AppError):
            apps.read_file(root, parts, limit=9)

    def test_symlinked_file_is_not_read_and_is_replaced_on_write(self):
        outside = os.path.join(self.root, 'secret')
        with open(outside, 'wb') as handle:
            handle.write(b'secret')
        os.symlink(outside, os.path.join(self.files, 'link'))
        root, parts = self.split('link')
        with self.assertRaises(apps.AppError):
            apps.read_file(root, parts)
        apps.write_file(root, parts, b'mine')
        with open(outside, 'rb') as handle:
            self.assertEqual(handle.read(), b'secret')
        self.assertFalse(os.path.islink(os.path.join(self.files, 'link')))
        self.assertEqual(apps.stat_path(root, parts)['kind'], 'file')

    def test_symlinked_directory_is_not_entered(self):
        outside = os.path.join(self.root, 'outside')
        os.makedirs(outside)
        with open(os.path.join(outside, 'f'), 'wb') as handle:
            handle.write(b'x')
        os.symlink(outside, os.path.join(self.files, 'dir'))
        for action in (lambda: apps.read_file(*self.split('dir/f')),
                       lambda: apps.write_file(*self.split('dir/g'), b'x'),
                       lambda: apps.list_dir(*self.split('dir')),
                       lambda: apps.remove_path(*self.split('dir/f'))):
            with self.assertRaises(apps.AppError):
                action()
        self.assertEqual(os.listdir(outside), ['f'])
        # Removing the link removes the link, not what it points to.
        self.assertEqual(apps.stat_path(*self.split('dir'))['kind'], 'symlink')
        apps.remove_path(*self.split('dir'), recursive=True)
        self.assertEqual(os.listdir(outside), ['f'])

    def test_write_onto_directory_is_refused(self):
        os.makedirs(os.path.join(self.files, 'd'))
        with self.assertRaises(apps.AppError):
            apps.write_file(*self.split('d'), b'x')
        self.assertEqual([n for n in os.listdir(self.files)], ['d'])


if __name__ == '__main__':
    unittest.main()
