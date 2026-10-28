import importlib.util
import os
import tempfile
import unittest

spec = importlib.util.spec_from_file_location('terminal', os.path.join(os.path.dirname(__file__), 'caboose-terminal.py'))
terminal = importlib.util.module_from_spec(spec)
spec.loader.exec_module(terminal)


class Logic(unittest.TestCase):
    def test_attach(self):
        self.assertEqual(terminal.parse_attach('/?cols=80&rows=24'), (80, 24, None, None))
        session = 'a' * 32
        self.assertEqual(terminal.parse_attach(f'/?cols=1000&rows=500&session={session}&offset=12'), (1000, 500, session, 12))
        for target in ('/?cols=0&rows=24', '/?cols=80', '/?cols=1001&rows=24', '/?cols=80&rows=501', '/?cols=8x&rows=24',
                       '/?cols=80&rows=24&session=xyz', '/?cols=80&rows=24&offset=3', f'/?cols=80&rows=24&session={session}&offset=-1'):
            with self.assertRaises(terminal.BadRequest, msg=target):
                terminal.parse_attach(target)

    def test_start(self):
        import base64
        import json
        encode = lambda value: base64.urlsafe_b64encode(json.dumps(value).encode()).decode().rstrip('=')
        argv = ['/bin/sh', '/home/caboose/sign-in.sh', 'claude', '/login']
        self.assertEqual(terminal.parse_start(f'/start?cols=80&rows=24&argv={encode(argv)}'), (80, 24, argv))
        for value in ([], ['sh'], ['/bin/sh', 3], ['/bin/sh', 'a\0b'], ['/bin/sh'] * 65, {'argv': ['/bin/sh']}, ['/bin/sh', 'x' * 4097]):
            with self.assertRaises(terminal.BadRequest, msg=value):
                terminal.parse_start(f'/start?cols=80&rows=24&argv={encode(value)}')
        for target in ('/start?cols=80&rows=24', '/start?cols=80&rows=24&argv=%%%', f'/start?cols=0&rows=24&argv={encode(argv)}'):
            with self.assertRaises(terminal.BadRequest, msg=target):
                terminal.parse_start(target)

    def test_control(self):
        self.assertEqual(terminal.parse_control('{"type":"resize","cols":120,"rows":40}'), ('resize', 120, 40))
        self.assertEqual(terminal.parse_control('{"type":"hangup"}'), ('hangup',))
        for text in ('nope', '[]', '{"type":"resize","cols":0,"rows":4}', '{"type":"resize","cols":true,"rows":4}',
                     '{"type":"resize","cols":2.5,"rows":4}', '{"type":"exec"}'):
            with self.assertRaises(terminal.BadRequest, msg=text):
                terminal.parse_control(text)

    def test_replay(self):
        replay = terminal.Replay(limit=16)
        replay.append(b'hello ')
        self.assertEqual(replay.since(None), (0, b'hello ', True))
        self.assertEqual(replay.since(2), (2, b'llo ', False))
        self.assertEqual(replay.since(6), (6, b'', False))
        # An offset the client cannot have (from another run) resets it.
        self.assertEqual(replay.since(99), (0, b'hello ', True))
        replay.append(b'world\nmore text')
        self.assertEqual(replay.start, 5)
        self.assertEqual(replay.end, 21)
        # Trimmed output resumes at a line boundary.
        self.assertEqual(replay.since(1), (12, b'more text', True))
        self.assertEqual(replay.since(14), (14, b're text', False))

    def test_replay_utf8(self):
        replay = terminal.Replay(limit=4)
        replay.append('aé€'.encode())  # 61 c3a9 e282ac: the é is cut in half
        self.assertEqual(replay.since(None), (3, '€'.encode(), True))

    def test_screen(self):
        screen = terminal.Screen()
        screen.feed(b'\x1b[?1049h\x1b[?25l\x1b[?20')
        screen.feed(b'04h text \x1b]0;caboose@caboose: ~/src\x07')
        self.assertEqual(screen.changed_modes(), {'25': False, '1049': True, '2004': True})
        self.assertEqual(screen.title, 'caboose@caboose: ~/src')
        screen.feed(b'\x1b[?1049;2004l\x1b[?25h\x1b]2;vim \x1b[31m')
        self.assertEqual(screen.changed_modes(), {})
        self.assertEqual(screen.title, 'caboose@caboose: ~/src')
        screen.feed(b'\x1b]2;bad\x01title\x1b\\')
        self.assertEqual(screen.title, 'badtitle')

    def test_environment(self):
        with tempfile.NamedTemporaryFile('w', delete=False) as f:
            f.write("WAYLAND_DISPLAY='wayland-caboose-0'\nDISPLAY=':110'\nXAUTHORITY='/run/a b/x'\nNOTE='it'\\''s'\n# comment\nbad line\n")
        try:
            env = terminal.display_env(f.name)
        finally:
            os.unlink(f.name)
        self.assertEqual(env, {'WAYLAND_DISPLAY': 'wayland-caboose-0', 'DISPLAY': ':110', 'XAUTHORITY': '/run/a b/x', 'NOTE': "it's"})
        self.assertEqual(terminal.display_env('/nonexistent'), {})

    def test_shell_environment(self):
        user = terminal.pwd.struct_passwd(('caboose', 'x', 1000, 1000, '', '/home/caboose', '/bin/bash'))
        env = terminal.shell_environment(user, {'HOME': '/root', 'LD_LIBRARY_PATH': '/usr/lib/wsl/lib', 'LD_PRELOAD': '',
                                                'CABOOSE_TERMINAL_PORT': '1', 'TERM': 'dumb', 'INVOCATION_ID': 'x'})
        self.assertEqual(env['HOME'], '/home/caboose')
        self.assertEqual(env['LD_LIBRARY_PATH'], '/usr/lib/wsl/lib')
        self.assertEqual((env['TERM'], env['COLORTERM'], env['SHELL'], env['USER']), ('xterm-256color', 'truecolor', '/bin/bash', 'caboose'))
        for name in ('LD_PRELOAD', 'CABOOSE_TERMINAL_PORT', 'INVOCATION_ID'):
            self.assertNotIn(name, env)

    def test_token(self):
        with tempfile.NamedTemporaryFile('wb', delete=False) as f:
            f.write(b'secret')
        try:
            self.assertTrue(terminal.authorized('Bearer secret', f.name))
            for header in (None, '', 'secret', 'Bearer secre', 'Bearer secret2', 'Basic secret'):
                self.assertFalse(terminal.authorized(header, f.name))
            self.assertFalse(terminal.authorized('Bearer secret', '/nonexistent'))
        finally:
            os.unlink(f.name)


if __name__ == '__main__':
    unittest.main()
