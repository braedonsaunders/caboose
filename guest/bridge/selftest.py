#!/usr/bin/python3
"""Checks bridgecore's pure logic; runs anywhere with Python 3 (no D-Bus): python3 selftest.py"""
import importlib.machinery
import importlib.util
import os
import pathlib
import sys
import tempfile
import threading
import time
import unittest

sys.path.insert(0, os.path.dirname(os.path.realpath(__file__)))
import bridgecore as core  # noqa: E402


class Requests(unittest.TestCase):
    def test_open_request_from_portal_options(self):
        options = {
            'accept_label': '_Open', 'multiple': True,
            'filters': [('Documents', [(0, '*.odt'), (1, 'application/pdf'), (1, 'not a type')]), ('All', [(0, '*')])],
            'current_filter': ('All', [(0, '*')]),
            'current_folder': b'/home/caboose/Documents\0',
        }
        r = core.new_request('file.open', 'org.example.App', 'Open\x07 File', options, now=10)
        self.assertRegex(r['id'], core.ID)
        self.assertEqual(r['title'], 'Open File')
        self.assertTrue(r['multiple'])
        self.assertEqual(r['filters'][0], {'name': 'Documents', 'patterns': ['*.odt'], 'mimeTypes': ['application/pdf']})
        self.assertEqual(r['currentFilter'], 1)
        self.assertEqual(r['currentFolder'], '/home/caboose/Documents')
        self.assertEqual(r['currentName'], '')
        self.assertEqual(r['created'], 10)

    def test_current_filter_outside_the_list_is_added(self):
        filters, index = core.portal_filters([('A', [(0, '*.a')])], ('B', [(0, '*.b')]))
        self.assertEqual([f['name'] for f in filters], ['A', 'B'])
        self.assertEqual(index, 1)

    def test_save_request_takes_name_and_folder_from_current_file(self):
        r = core.new_request('file.save', '', 'Save', {'current_file': b'/home/caboose/Notes/a.txt\0', 'multiple': True})
        self.assertEqual((r['currentFolder'], r['currentName'], r['multiple']), ('/home/caboose/Notes', 'a.txt', False))
        r = core.new_request('file.save', '', 'Save', {'current_name': 'x/y.txt', 'current_folder': b'/etc\0'})
        self.assertEqual((r['currentFolder'], r['currentName']), ('', 'xy.txt'))

    def test_answers(self):
        request = {'type': 'file.open', 'multiple': False, 'directory': False, 'filters': [{}]}
        ident = 'a' * 32
        self.assertEqual(core.check_answer({'id': ident, 'response': 'cancel'}), {'id': ident, 'response': 'cancel'})
        ok = core.check_answer({'id': ident, 'response': 'ok', 'paths': ['/home/caboose/a'], 'filter': 0}, request)
        self.assertEqual(ok['paths'], ['/home/caboose/a'])
        for bad in [
            {'id': 'x', 'response': 'cancel'}, {'id': ident, 'response': 'cancel', 'paths': []},
            {'id': ident, 'response': 'ok', 'paths': ['/etc/passwd']}, {'id': ident, 'response': 'ok', 'paths': ['/home/caboose/../x']},
            {'id': ident, 'response': 'ok', 'paths': ['/home/caboose/a', '/home/caboose/b']},
            {'id': ident, 'response': 'ok', 'paths': ['/home/caboose/a'], 'filter': 1},
            {'id': ident, 'response': 'ok', 'paths': ['/home/caboose/a'], 'filter': True},
        ]:
            with self.assertRaises(core.Invalid, msg=bad):
                core.check_answer(bad, request)

    def test_chosen_paths_must_exist_as_asked(self):
        files = {'/home/caboose/a.txt'}
        dirs = {'/home/caboose', '/home/caboose/Docs'}
        exists = lambda p: p in files or p in dirs
        isdir = lambda p: p in dirs
        opening = {'type': 'file.open', 'directory': False}
        self.assertEqual(core.chosen(opening, {'paths': ['/home/caboose/a.txt']}, exists, isdir), ['/home/caboose/a.txt'])
        self.assertIsNone(core.chosen(opening, {'paths': ['/home/caboose/Docs']}, exists, isdir))
        self.assertIsNone(core.chosen({'type': 'file.open', 'directory': True}, {'paths': ['/home/caboose/a.txt']}, exists, isdir))
        saving = {'type': 'file.save', 'directory': False}
        self.assertEqual(core.chosen(saving, {'paths': ['/home/caboose/Docs/new.odt']}, exists, isdir), ['/home/caboose/Docs/new.odt'])
        self.assertIsNone(core.chosen(saving, {'paths': ['/home/caboose/Missing/new.odt']}, exists, isdir))
        self.assertIsNone(core.chosen(saving, {'paths': ['/home/caboose/Docs']}, exists, isdir))


class Scan(unittest.TestCase):
    def test_scan_requests(self):
        pdf = core.new_scan_request('pdf', now=7)
        self.assertRegex(pdf['id'], core.ID)
        self.assertEqual((pdf['type'], pdf['multiple'], pdf['directory'], pdf['currentFilter'], pdf['created']), ('scan', False, False, 0, 7))
        self.assertEqual(pdf['filters'], [{'name': 'PDF', 'patterns': ['*.pdf'], 'mimeTypes': ['application/pdf']}])
        jpeg = core.new_scan_request('jpeg')
        self.assertTrue(jpeg['multiple'])
        self.assertEqual(jpeg['filters'][0]['mimeTypes'], ['image/jpeg'])
        # The request's filter is a copy: changing it leaves the format alone.
        jpeg['filters'][0]['patterns'].append('*.png')
        self.assertEqual(core.SCAN_FORMATS['jpeg'][0]['patterns'], ['*.jpg', '*.jpeg'])

    def test_scan_answers(self):
        ident = 'b' * 32
        pdf, jpeg = core.new_scan_request('pdf'), core.new_scan_request('jpeg')
        two = {'id': ident, 'response': 'ok', 'paths': ['/home/caboose/p1.jpg', '/home/caboose/p2.jpg'], 'filter': 0}
        self.assertEqual(core.check_answer(two, jpeg)['paths'], two['paths'])
        with self.assertRaises(core.Invalid):
            core.check_answer(two, pdf)
        self.assertEqual(core.check_answer({'id': ident, 'response': 'computer'}, pdf)['response'], 'computer')
        files = {'/home/caboose/p1.jpg'}
        exists, isdir = (lambda p: p in files or p == '/home/caboose'), (lambda p: p == '/home/caboose')
        self.assertEqual(core.chosen(jpeg, {'paths': ['/home/caboose/p1.jpg']}, exists, isdir), ['/home/caboose/p1.jpg'])
        self.assertIsNone(core.chosen(jpeg, two, exists, isdir))

    def test_output(self):
        dirs = {'/home/caboose', '/home/caboose/Scans'}
        files = {'/home/caboose/a.pdf'}
        exists, isdir = (lambda p: p in dirs or p in files), (lambda p: p in dirs)
        self.assertIsNone(core.scan_output_problem('/home/caboose/Scans', 'pdf', exists, isdir))
        self.assertIsNone(core.scan_output_problem('/home/caboose/a.pdf', 'pdf', exists, isdir))
        self.assertIsNone(core.scan_output_problem('/home/caboose/Pages', 'jpeg', exists, isdir))
        self.assertIn('not a folder', core.scan_output_problem('/home/caboose/a.pdf', 'jpeg', exists, isdir))
        self.assertIn('does not exist', core.scan_output_problem('/home/caboose/Missing/a.pdf', 'pdf', exists, isdir))
        scanned = ['/home/caboose/Caboose Documents/u/Scan 2026-10-30 14.05.pdf']
        self.assertEqual(core.scan_destinations(scanned, '/home/caboose/r.pdf', 'pdf', isdir), [(scanned[0], '/home/caboose/r.pdf')])
        self.assertEqual(core.scan_destinations(scanned, '/home/caboose/Scans', 'pdf', isdir),
                         [(scanned[0], '/home/caboose/Scans/Scan 2026-10-30 14.05.pdf')])
        pages = ['/home/caboose/Caboose Documents/u/Scan Page 1.jpg', '/home/caboose/Caboose Documents/u/Scan Page 2.jpg']
        self.assertEqual([d for _, d in core.scan_destinations(pages, '/home/caboose/Pages', 'jpeg', isdir)],
                         ['/home/caboose/Pages/Scan Page 1.jpg', '/home/caboose/Pages/Scan Page 2.jpg'])


class ScanCommand(unittest.TestCase):
    """caboose-scan's wait against a bridge folder in a temporary directory, with the host's
    part played here."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        root = pathlib.Path(self.tmp.name)
        self.saved = {name: getattr(core, name) for name in ('ROOT', 'REQUESTS', 'CLAIMED', 'RESPONSES', 'CANCELS', 'PRESENT', 'CLAIM_SECONDS', 'ABSENT_SECONDS')}
        core.ROOT, core.REQUESTS, core.CLAIMED = root, root / 'requests', root / 'claimed'
        core.RESPONSES, core.CANCELS, core.PRESENT = root / 'responses', root / 'cancels', root / 'present'
        core.CLAIM_SECONDS, core.ABSENT_SECONDS = 0.5, 0.5
        core.prepare()
        path = os.path.join(os.path.dirname(os.path.realpath(__file__)), 'caboose-scan')
        loader = importlib.machinery.SourceFileLoader('caboose_scan', path)
        self.scan = importlib.util.module_from_spec(importlib.util.spec_from_loader('caboose_scan', loader))
        loader.exec_module(self.scan)
        self.scan.POLL_SECONDS = 0.02

    def tearDown(self):
        for name, value in self.saved.items():
            setattr(core, name, value)
        self.tmp.cleanup()

    def host(self, answer, present=True):
        """Claims the request like `drain` and, when `answer` is given, answers it."""
        def run():
            deadline = time.time() + 2
            while time.time() < deadline:
                if present:
                    core.PRESENT.touch()
                for path in list(core.REQUESTS.glob('*.json')):
                    os.replace(path, core.CLAIMED / path.name)
                    if answer is not None:
                        core.write_json(core.RESPONSES / path.name, {'id': path.stem, **answer})
                    return
                time.sleep(0.01)
        thread = threading.Thread(target=run, daemon=True)
        thread.start()
        return thread

    def write(self, request):
        core.write_json(core.REQUESTS / f"{request['id']}.json", request)
        return request

    def test_answered(self):
        request = self.write(core.new_scan_request('pdf'))
        self.host({'response': 'cancel'})
        self.assertEqual(self.scan.wait_for_answer(request), {'id': request['id'], 'response': 'cancel'})
        self.assertEqual(list(core.CLAIMED.iterdir()) + list(core.RESPONSES.iterdir()), [])

    def test_unclaimed_fails_fast(self):
        request = self.write(core.new_scan_request('pdf'))
        started = time.monotonic()
        with self.assertRaises(SystemExit) as raised:
            self.scan.wait_for_answer(request)
        self.assertEqual(raised.exception.code, 3)
        self.assertLess(time.monotonic() - started, 2)
        self.assertEqual(list(core.REQUESTS.iterdir()), [])

    def test_phone_leaving_withdraws(self):
        request = self.write(core.new_scan_request('jpeg'))
        self.host(None, present=False)
        with self.assertRaises(SystemExit) as raised:
            self.scan.wait_for_answer(request)
        self.assertEqual(raised.exception.code, 3)
        self.assertTrue((core.CANCELS / request['id']).exists())
        self.assertEqual(list(core.CLAIMED.iterdir()), [])


class Appearance(unittest.TestCase):
    look = {'colorScheme': 'light', 'accent': '#ff9500', 'contrast': 'high', 'reducedMotion': True, 'textScale': 1.25}

    def test_validation(self):
        self.assertEqual(core.check_appearance(self.look)['accent'], '#FF9500')
        for bad in [{}, {**self.look, 'textScale': 3}, {**self.look, 'accent': 'orange'}, {**self.look, 'reducedMotion': 1}, {**self.look, 'x': 1}]:
            with self.assertRaises(core.Invalid):
                core.check_appearance(bad)

    def test_settings(self):
        look = core.check_appearance(self.look)
        appearance = core.appearance_settings(look)
        self.assertEqual(appearance['color-scheme'], ('u', 2))
        self.assertEqual(appearance['contrast'], ('u', 1))
        self.assertEqual(appearance['reduced-motion'], ('u', 1))
        self.assertAlmostEqual(appearance['accent-color'][1][0], 1.0)
        interface = core.interface_settings(look, {'WhiteSur-Light', 'WhiteSur-Dark'})
        self.assertEqual(interface['gtk-theme'], ('s', 'WhiteSur-Light'))
        self.assertEqual(interface['color-scheme'], ('s', 'default'))
        self.assertEqual(interface['accent-color'], ('s', 'orange'))
        self.assertEqual(interface['text-scaling-factor'], ('d', 1.25))
        self.assertEqual(interface['enable-animations'], ('b', False))
        # Without the light WhiteSur variant, light is Adwaita.
        self.assertEqual(core.interface_settings(look, {'WhiteSur-Dark'})['gtk-theme'], ('s', 'Adwaita'))

    def test_named_accents(self):
        self.assertEqual(core.named_accent('#0A84FF'), 'blue')
        self.assertEqual(core.named_accent('#34C759'), 'green')
        self.assertEqual(core.named_accent('#FF3B30'), 'red')
        self.assertEqual(core.named_accent('#AF52DE'), 'purple')
        self.assertEqual(core.named_accent('#8E8E93'), 'slate')

    def test_settings_ini_keeps_other_keys(self):
        existing = '[Settings]\ngtk-theme-name=WhiteSur-Dark\ngtk-font-name=Inter 10\ngtk-application-prefer-dark-theme=1\n'
        updated = core.settings_ini(existing, core.check_appearance(self.look), {'WhiteSur-Light'})
        self.assertIn('gtk-theme-name=WhiteSur-Light\n', updated)
        self.assertIn('gtk-font-name=Inter 10\n', updated)
        self.assertIn('gtk-application-prefer-dark-theme=0\n', updated)
        self.assertIn('gtk-enable-animations=0\n', updated)
        self.assertEqual(updated.count('[Settings]'), 1)
        self.assertIn('gtk-theme-name=', core.settings_ini(None, core.check_appearance(self.look), set()))


class NowPlaying(unittest.TestCase):
    def test_pick_player(self):
        players = {
            'a': {'status': 'Paused', 'playedAt': 5, 'pausedAt': 9},
            'b': {'status': 'Playing', 'playedAt': 3, 'pausedAt': 0},
            'c': {'status': 'Playing', 'playedAt': 4, 'pausedAt': 0},
            'd': {'status': 'Stopped', 'playedAt': 10, 'pausedAt': 10},
        }
        self.assertEqual(core.pick_player(players), 'c')
        players['b']['status'] = players['c']['status'] = 'Paused'
        self.assertEqual(core.pick_player(players), 'a')
        self.assertIsNone(core.pick_player({'d': players['d']}))

    def test_track_state(self):
        metadata = {'xesam:title': 'Teardrop\n', 'xesam:artist': ['Massive Attack', 'Liz Fraser'], 'xesam:album': 'Mezzanine',
                    'mpris:length': 330_000_000, 'mpris:artUrl': 'file:///tmp/cover.png'}
        caps = {'CanPlay': True, 'CanPause': True, 'CanGoNext': False, 'CanGoPrevious': True, 'CanSeek': True}
        s = core.track_state('org.mpris.MediaPlayer2.spotify', 2, 'Spotify', 'Playing', metadata, 400_000_000, 1.0, caps, 1234.6)
        self.assertRegex(s['id'], core.PLAYER_ID)
        self.assertTrue(s['id'].endswith('-2'))
        self.assertEqual((s['title'], s['artist'], s['artwork']), ('Teardrop', 'Massive Attack, Liz Fraser', None))
        self.assertEqual((s['position'], s['duration'], s['paused'], s['canNext']), (330.0, 330.0, False, False))
        self.assertEqual(s['updatedAt'], 1234)
        live = core.track_state('org.mpris.MediaPlayer2.mpv', 0, '', 'Paused', {'mpris:artUrl': 'https://x/y.jpg'}, None, 'x', {}, 0)
        self.assertEqual((live['player'], live['duration'], live['rate'], live['artwork'], live['paused']), ('mpv', None, 1.0, 'https://x/y.jpg', True))

    def test_track_identity(self):
        self.assertEqual(core.track_identity({'mpris:trackid': '/t/1'}), '/t/1')
        self.assertNotEqual(core.track_identity({'xesam:title': 'a'}), core.track_identity({'xesam:title': 'b'}))
        self.assertEqual(core.track_identity({'mpris:trackid': '/org/mpris/MediaPlayer2/TrackList/NoTrack', 'xesam:title': 'a'}),
                         core.track_identity({'xesam:title': 'a'}))

    def test_commands(self):
        self.assertEqual(core.check_command({'seq': 5, 'id': 'a-1', 'action': 'seek', 'position': 3}, 4)['position'], 3)
        self.assertIsNone(core.check_command({'seq': 4, 'id': 'a-1', 'action': 'play'}, 4))
        self.assertIsNone(core.check_command({'seq': 5, 'id': 'a/1', 'action': 'play'}, 4))
        self.assertIsNone(core.check_command({'seq': 5, 'id': 'a-1', 'action': 'stop'}, 4))
        self.assertIsNone(core.check_command({'seq': 5, 'id': 'a-1', 'action': 'seek'}, 4))
        self.assertIsNone(core.check_command({'seq': True, 'id': 'a-1', 'action': 'play'}, 0))


class Environment(unittest.TestCase):
    def test_read_env(self):
        import tempfile
        with tempfile.NamedTemporaryFile('w', delete=False) as f:
            f.write("WAYLAND_DISPLAY='wayland-caboose-0'\nQT_QPA_PLATFORM='wayland;xcb'\nODD='it'\\''s'\nbad line\n")
        try:
            env = core.read_env(f.name)
        finally:
            os.unlink(f.name)
        self.assertEqual(env, {'WAYLAND_DISPLAY': 'wayland-caboose-0', 'QT_QPA_PLATFORM': 'wayland;xcb', 'ODD': "it's"})


if __name__ == '__main__':
    unittest.main()
