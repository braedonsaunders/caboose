"""Unit tests for caboose-game-run's manifest, paths, fallback and socket framing."""
import contextlib
import importlib.machinery
import importlib.util
import json
import io
import os
from pathlib import Path
import select
import socket
import tempfile
import unittest
import unittest.mock

HERE = Path(__file__).resolve().parent
loader = importlib.machinery.SourceFileLoader('caboose_game_run', str(HERE / 'caboose-game-run'))
spec = importlib.util.spec_from_loader(loader.name, loader)
run = importlib.util.module_from_spec(spec)
loader.exec_module(run)


class Home(unittest.TestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        self.home = Path(os.path.realpath(temp.name))
        self.bundle = self.home / 'games/example'
        (self.bundle / 'web').mkdir(parents=True)
        (self.bundle / 'web/index.html').write_text('<!DOCTYPE html>')

    def manifest(self, **fields):
        data = {'version': 1, 'title': 'Example', 'app_id': 'org.example.Game', 'root': 'web', 'entry': 'index.html'}
        data.update(fields)
        data = {k: v for k, v in data.items() if v is not None}
        (self.bundle / run.MANIFEST).write_text(json.dumps(data))
        return run.Game(self.bundle, self.home)

    def refused(self, **fields):
        with self.assertRaises(run.ManifestError):
            self.manifest(**fields)


class Manifest(Home):
    def test_hello_names_the_served_directory_relative_to_the_home(self):
        game = self.manifest(saves=[{'mount': '/powder', 'path': '.local/share/The Powder Toy'}])
        self.assertEqual(game.hello, {'version': 1, 'title': 'Example', 'app_id': 'org.example.Game',
                                      'root': 'games/example/web', 'entry': 'index.html',
                                      'saves': [{'mount': '/powder', 'path': '.local/share/The Powder Toy'}]})

    def test_manifest_path_and_default_root(self):
        (self.bundle / 'index.html').write_text('')
        self.manifest(root=None)
        game = run.Game(self.bundle / run.MANIFEST, self.home)
        self.assertEqual(game.hello['root'], 'games/example')
        self.assertNotIn('saves', game.hello)

    def test_paths_are_normalised(self):
        (self.bundle / 'web/sub').mkdir()
        (self.bundle / 'web/sub/page.html').write_text('')
        game = self.manifest(root='./web/', entry='sub//page.html')
        self.assertEqual((game.hello['root'], game.hello['entry']), ('games/example/web', 'sub/page.html'))

    def test_required_fields(self):
        self.refused(version=2)
        self.refused(version=True)
        self.refused(title='')
        self.refused(app_id='not an id')
        self.refused(app_id='trailing.')
        self.refused(entry=None)
        self.refused(entry='missing.html')

    def test_window(self):
        game = self.manifest(window={'size': [1280, 800], 'min': [640, 400], 'max': [1920, 1200]})
        self.assertEqual((game.size, game.min, game.max), ((1280, 800), (640, 400), (1920, 1200)))
        self.refused(window={'size': [0, 800]})
        self.refused(window={'min': [640]})
        self.refused(window={'min': [800, 400], 'max': [640, 400]})
        self.refused(window={'size': [True, 800]})

    def test_saves(self):
        self.refused(saves=[{'mount': 'powder', 'path': 'saves'}])
        self.refused(saves=[{'mount': '/', 'path': 'saves'}])
        self.refused(saves=[{'mount': '/a/../b', 'path': 'saves'}])
        self.refused(saves=[{'mount': '/a', 'path': 'x'}, {'mount': '/a', 'path': 'y'}])
        self.refused(saves=[{'mount': '/a', 'path': '.'}])
        self.refused(saves={'mount': '/a', 'path': 'x'})

    def test_unknown_keys_are_ignored(self):
        self.assertEqual(self.manifest(future={'x': 1}).title, 'Example')

    def test_the_home_itself_is_not_a_root(self):
        (self.home / 'index.html').write_text('')
        self.refused(root='../..')
        (self.home / run.MANIFEST).write_text(json.dumps({'version': 1, 'title': 'T', 'app_id': 'a.b', 'entry': 'index.html'}))
        with self.assertRaisesRegex(run.ManifestError, 'home itself'):
            run.Game(self.home, self.home)

    def test_bundled_icon(self):
        self.assertIsNone(self.manifest().icon)
        (self.bundle / run.ICON).write_bytes(b'')
        self.assertEqual(self.manifest().icon, self.bundle / run.ICON)


class PathSafety(Home):
    def test_no_parent_or_absolute_paths(self):
        self.refused(root='../example/web')
        self.refused(root='/etc')
        self.refused(entry='../web/index.html')
        self.refused(entry='/index.html')
        self.refused(saves=[{'mount': '/s', 'path': '../outside'}])
        self.refused(saves=[{'mount': '/s', 'path': '/tmp/saves'}])
        self.refused(native_fallback=['native/../../../bin/sh'])
        self.refused(native_fallback=['~/../escape'])
        self.refused(native_fallback=[])
        self.refused(native_fallback=['native/game', ''])

    def test_bundle_must_be_inside_the_home(self):
        with tempfile.TemporaryDirectory() as other:
            Path(other, run.MANIFEST).write_text('{}')
            with self.assertRaisesRegex(run.ManifestError, 'inside'):
                run.Game(other, self.home)

    def test_no_symbolic_links_on_the_way(self):
        outside = tempfile.TemporaryDirectory()
        self.addCleanup(outside.cleanup)
        Path(outside.name, 'index.html').write_text('')
        (self.bundle / 'linked').symlink_to(outside.name)
        self.refused(root='linked')
        (self.bundle / 'web/page.html').symlink_to(Path(outside.name, 'index.html'))
        self.refused(entry='page.html')
        (self.home / '.local').mkdir()
        (self.home / '.local/share').symlink_to(outside.name)
        self.refused(saves=[{'mount': '/s', 'path': '.local/share/Game'}])
        (self.bundle / 'native').symlink_to(outside.name)
        self.refused(native_fallback=['native/game'])
        (self.bundle / run.ICON).symlink_to(Path(outside.name, 'index.html'))
        self.refused()
        (self.bundle / run.ICON).unlink()
        (self.home / 'bundle-link').symlink_to(self.bundle)
        (self.bundle / run.MANIFEST).write_text(json.dumps({'version': 1, 'title': 'T', 'app_id': 'a.b', 'root': 'web', 'entry': 'index.html'}))
        with self.assertRaisesRegex(run.ManifestError, 'symbolic link'):
            run.Game(self.home / 'bundle-link', self.home)

    def test_save_directories_are_created_but_never_through_a_file(self):
        game = self.manifest(saves=[{'mount': '/s', 'path': '.local/share/Game'}])
        game.prepare_saves()
        self.assertTrue((self.home / '.local/share/Game').is_dir())
        game.prepare_saves()
        game = self.manifest(saves=[{'mount': '/s', 'path': 'file/Game'}])
        (self.home / 'file').write_text('')
        with self.assertRaises(run.ManifestError):
            game.prepare_saves()


class Fallback(Home):
    def executable(self, path):
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text('#!/bin/sh\n')
        path.chmod(0o755)
        return path

    def test_bundle_relative_program_and_home_arguments(self):
        program = self.executable(self.bundle / 'native/powder')
        game = self.manifest(native_fallback=['native/powder', 'ddir', '~/.local/share/The Powder Toy', 'x~/y'])
        self.assertEqual(game.native_command(), [str(program), 'ddir', f'{self.home}/.local/share/The Powder Toy', 'x~/y'])

    def test_home_relative_program(self):
        program = self.executable(self.home / 'bin/game')
        self.assertEqual(self.manifest(native_fallback=['~/bin/game']).native_command(), [str(program)])

    def test_program_on_path(self):
        directory = self.home / 'path'
        program = self.executable(directory / 'native-game')
        game = self.manifest(native_fallback=['native-game', '-f'])
        self.assertEqual(game.native_command(path=str(directory)), [str(program), '-f'])
        self.assertIsNone(game.native_command(path=str(self.home / 'nowhere')))

    def test_missing_or_not_executable_program_means_no_fallback(self):
        game = self.manifest(native_fallback=['native/powder'])
        self.assertIsNone(game.native_command())
        (self.bundle / 'native').mkdir()
        (self.bundle / 'native/powder').write_text('')
        self.assertIsNone(game.native_command())
        self.assertIsNone(self.manifest().native_command())

    def test_answers(self):
        answers = run.Answers(['/bin/game'])
        self.assertEqual(answers.mode('local'), ('native', None))
        answers = run.Answers(None)
        self.assertEqual(answers.mode('local'), ('status', run.ASK))
        answers = run.Answers(['/bin/game'])
        self.assertEqual(answers.mode('handoff'), ('status', run.PLAYING))
        self.assertEqual(answers.mode('local'), ('status', run.ASK))
        self.assertEqual(answers.mode('handoff'), ('status', run.PLAYING))

    def test_a_declined_game_runs_natively_even_after_handoff(self):
        answers = run.Answers(['/bin/game'])
        self.assertEqual(answers.mode('handoff'), ('status', run.PLAYING))
        self.assertEqual(answers.mode('declined'), ('native', None))
        answers = run.Answers(None)
        self.assertEqual(answers.mode('handoff'), ('status', run.PLAYING))
        self.assertEqual(answers.mode('declined'), ('status', run.DECLINED))

    def test_declined_is_read_from_a_local_mode(self):
        def mode(value):
            payload = run.encode(value)
            return bytes([run.MODE]) + len(payload).to_bytes(4, 'little') + payload
        stream = mode({'mode': 'local', 'window': 3, 'declined': True}) + mode({'mode': 'local', 'declined': False})
        self.assertEqual(run.modes(run.Frames(), stream), ['declined', 'local'])


class Cbor(unittest.TestCase):
    def test_round_trip(self):
        for value in (0, 23, 24, 255, 256, 65535, 65536, 2**32 - 1, 2**32, 2**64 - 1, -1, -25, '', 'é',
                      True, False, None, [], [1, [2, 'x']], {'a': {'b': [True]}}, b'\x00\xff'):
            self.assertEqual(run.decode(run.encode(value)), value)

    def test_shortest_integers_and_definite_lengths(self):
        self.assertEqual(run.encode(23), b'\x17')
        self.assertEqual(run.encode(24), b'\x18\x18')
        self.assertEqual(run.encode(256), b'\x19\x01\x00')
        self.assertEqual(run.encode(65536), b'\x1a\x00\x01\x00\x00')
        self.assertEqual(run.encode(2**32), b'\x1b\x00\x00\x00\x01\x00\x00\x00\x00')
        self.assertEqual(run.encode('ab'), b'\x62ab')
        self.assertEqual(run.encode([1]), b'\x81\x01')

    def test_canonical_key_order_is_shorter_first_then_bytewise(self):
        encoded = run.encode({'title': 1, 'b': 2, 'aa': 3, 'a': 4, 'entry': 5})
        self.assertEqual(encoded, bytes([0xa5, 0x61]) + b'a' + b'\x04' + b'\x61b\x02' + b'\x62aa\x03' + b'\x65entry\x05' + b'\x65title\x01')
        self.assertEqual(run.encode({'b': 1, 'a': 2}), run.encode({'a': 2, 'b': 1}))

    def test_hello_matches_the_contract(self):
        message = {'version': 1, 'title': 'T', 'app_id': 'a.b', 'root': 'r', 'entry': 'e'}
        keys = list(run.decode(run.encode(message)))
        self.assertEqual(keys, ['root', 'entry', 'title', 'app_id', 'version'])

    def test_malformed_input_is_refused(self):
        for data in (b'', b'\x18', b'\x62a', b'\x5f', b'\x9f\xff', b'\xa1\x01\x02', b'\xa2\x61a\x01\x61a\x02',
                     b'\xc1\x00', b'\x01\x02', b'\x62\xff\xfe', b'\xf8\x20'):
            with self.subTest(data=data), self.assertRaises(run.ProtocolError):
                run.decode(data)

    def test_floats_decode(self):
        self.assertEqual(run.decode(b'\xf9\x3c\x00'), 1.0)
        self.assertEqual(run.decode(b'\xfb\x3f\xf8\x00\x00\x00\x00\x00\x00'), 1.5)


class Framing(unittest.TestCase):
    def test_frame_layout(self):
        payload = run.encode({'mode': 'local'})
        self.assertEqual(run.frame(run.MODE, {'mode': 'local'}), b'\x81' + len(payload).to_bytes(4, 'little') + payload)

    def test_split_reads_and_unknown_types_are_skipped(self):
        stream = (run.frame(0x7f, {'something': ['new']}) + run.frame(run.MODE, {'mode': 'handoff', 'window': 3, 'extra': 1})
                  + run.frame(run.MODE, {'mode': 'sideways'}) + run.frame(run.MODE, {'mode': 'local'}))
        frames, found = run.Frames(), []
        for i in range(len(stream)):
            found += run.modes(frames, stream[i:i + 1])
        self.assertEqual(found, ['handoff', 'local'])
        self.assertEqual(frames.buffer, bytearray())

    def test_payload_limit(self):
        frames = run.Frames()
        at_limit = bytes([0x7f]) + run.LIMIT.to_bytes(4, 'little')
        self.assertEqual(frames.feed(at_limit + b'\x00' * run.LIMIT), [(0x7f, b'\x00' * run.LIMIT)])
        with self.assertRaises(run.ProtocolError):
            run.Frames().feed(bytes([0x7f]) + (run.LIMIT + 1).to_bytes(4, 'little'))
        with self.assertRaises(ValueError):
            run.frame(run.HELLO, {'title': 'x' * run.LIMIT})

    def test_malformed_mode_is_a_protocol_error(self):
        with self.assertRaises(run.ProtocolError):
            run.modes(run.Frames(), b'\x81\x01\x00\x00\x00\x5f')

    def test_oversized_manifest_is_refused(self):
        with tempfile.TemporaryDirectory() as temp:
            home = Path(os.path.realpath(temp))
            (home / 'g').mkdir()
            (home / 'g/index.html').write_text('')
            saves = [{'mount': f'/m{i}' + 'x' * 1000, 'path': f'p{i}/' + '/'.join(['y' * 200] * 6)} for i in range(32)]
            (home / 'g' / run.MANIFEST).write_text(json.dumps({'version': 1, 'title': 'T', 'app_id': 'a.b', 'entry': 'index.html', 'saves': saves}))
            with self.assertRaisesRegex(run.ManifestError, 'too large'):
                run.Game(home / 'g', home)


class Socket(unittest.TestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        self.path = os.path.join(temp.name, 'game.sock')
        self.server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.addCleanup(self.server.close)
        self.server.bind(self.path)
        self.server.listen()

    def accept(self, hello):
        link = run.Link(self.path, hello)
        self.addCleanup(link.close)
        peer, _ = self.server.accept()
        self.addCleanup(peer.close)
        return link, peer

    def wait(self, link):
        for _ in range(50):
            select.select([link], [], [], 0.1)
            found = link.receive()
            if found:
                return found
        self.fail('no mode arrived')

    def test_hello_then_modes(self):
        hello = {'version': 1, 'title': 'T', 'app_id': 'a.b', 'root': 'g/web', 'entry': 'index.html'}
        link, peer = self.accept(hello)
        header = peer.recv(5, socket.MSG_WAITALL)
        self.assertEqual(header[0], run.HELLO)
        payload = peer.recv(int.from_bytes(header[1:], 'little'), socket.MSG_WAITALL)
        self.assertEqual(payload, run.encode(hello))
        self.assertEqual(link.receive(), [])
        peer.sendall(run.frame(0x90, {'later': True}) + run.frame(run.MODE, {'mode': 'handoff', 'window': 7}))
        self.assertEqual(self.wait(link), ['handoff'])
        peer.sendall(run.frame(run.MODE, {'mode': 'local'}))
        self.assertEqual(self.wait(link), ['local'])
        peer.close()
        select.select([link], [], [], 5)
        with self.assertRaises(ConnectionError):
            link.receive()

    def test_oversized_payload_ends_the_link(self):
        link, peer = self.accept({'version': 1})
        peer.sendall(bytes([run.MODE]) + (run.LIMIT + 1).to_bytes(4, 'little'))
        select.select([link], [], [], 5)
        with self.assertRaises(run.ProtocolError):
            link.receive()

    def test_no_listener(self):
        with self.assertRaises(OSError):
            run.Link(self.path + '.missing', {'version': 1})


class Shipped(unittest.TestCase):
    def test_bundles_are_valid(self):
        for manifest in (HERE / 'games').glob(f'*/{run.MANIFEST}'):
            with self.subTest(bundle=manifest.parent.name):
                game = run.Game(manifest.parent, HERE)
                self.assertTrue(game.hello['root'].startswith('games/'))
                self.assertTrue((manifest.parent / 'icon.png').is_file())


class Command(Home):
    def test_without_a_game_socket_the_native_game_replaces_the_launcher(self):
        program = self.bundle / 'native/powder'
        program.parent.mkdir()
        program.write_text('#!/bin/sh\n')
        program.chmod(0o755)
        self.manifest(native_fallback=['native/powder', 'ddir', '~/.local/share/Example'],
                      saves=[{'mount': '/example', 'path': '.local/share/Example'}])
        executed = []

        class Executed(Exception):
            pass

        def execv(path, command):
            executed.append((path, command))
            raise Executed

        environment = {k: v for k, v in os.environ.items() if k != 'CABOOSE_GAME_SOCKET'}
        with unittest.mock.patch.dict(os.environ, {**environment, 'HOME': str(self.home)}, clear=True), \
                unittest.mock.patch.object(run.os, 'execv', execv), self.assertRaises(Executed):
            run.main(['caboose-game-run', str(self.bundle)])
        self.assertEqual(executed, [(str(program), [str(program), 'ddir', f'{self.home}/.local/share/Example'])])
        self.assertTrue((self.home / '.local/share/Example').is_dir())

    def test_usage_and_refusal(self):
        with contextlib.redirect_stderr(io.StringIO()) as errors:
            self.assertEqual(run.main(['caboose-game-run']), 2)
            with tempfile.TemporaryDirectory() as temp:
                self.assertEqual(run.main(['caboose-game-run', temp]), 2)
        self.assertIn('must be inside', errors.getvalue())


if __name__ == '__main__':
    unittest.main()
