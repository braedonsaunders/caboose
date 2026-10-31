import importlib.util
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location('quake_launch', ROOT / 'launch.py')
launch = importlib.util.module_from_spec(spec)
spec.loader.exec_module(launch)


class DependencyEnvironmentTests(unittest.TestCase):
    def test_verified_wrapper_matches_dependency_check(self):
        self.assertEqual(launch.digest(ROOT.parent / 'launch.sh'), launch.LAUNCH_SHA)
        manifest = json.loads((ROOT.parent / 'bundle-manifest.json').read_text())
        self.assertEqual(next(item['sha256'] for item in manifest if item['path'] == 'launch.sh'), launch.LAUNCH_SHA)
        with tempfile.TemporaryDirectory() as task:
            executable = Path(task) / 'vkquake'
            executable.write_text('#!/bin/sh\nprintf "%s\\n" "$LD_LIBRARY_PATH" "$SDL_VIDEODRIVER" "$@"\n')
            executable.chmod(0o755)
            for libraries in (None, '/private/deps/usr/lib/x86_64-linux-gnu'):
                for inherited in ('', '/existing/lib'):
                    with self.subTest(libraries=libraries, inherited=inherited):
                        env = launch.game_environment({'PATH': os.environ['PATH'],
                                                       'XDG_RUNTIME_DIR': task,
                                                       'WAYLAND_DISPLAY': 'wayland-test',
                                                       'LD_LIBRARY_PATH': inherited}, libraries)
                        env['CABOOSE_GAME_BUNDLE'] = task
                        result = subprocess.run(['/bin/sh', str(ROOT.parent / 'launch.sh'), '+map', 'start'],
                                                env=env, text=True, capture_output=True, check=True, timeout=3)
                        output = result.stdout.splitlines()
                        self.assertEqual(output[0], launch.loader_environment(env)['LD_LIBRARY_PATH'])
                        self.assertEqual(output[1:], ['wayland', '-basedir', task, '-window',
                                                     '-width', '640', '-height', '480', '+map', 'start'])

    def test_inherited_private_library_selection_is_preserved(self):
        env = launch.game_environment({'CABOOSE_GAME_LIBRARY_DIR': '/verified/lib',
                                       'LD_LIBRARY_PATH': '/existing/lib'}, '/verified/lib')
        self.assertEqual(env['CABOOSE_GAME_LIBRARY_DIR'], '/verified/lib')
        self.assertEqual(env['LD_LIBRARY_PATH'], '/existing/lib')

    def test_ambiguous_or_invalid_dependency_configuration_fails(self):
        for invalid in ('relative/lib', '/one:/two', 42, '/nul\0'):
            with self.subTest(invalid=invalid), self.assertRaises(RuntimeError):
                launch.game_environment({}, invalid)
        with self.assertRaisesRegex(RuntimeError, 'differs'):
            launch.game_environment({'CABOOSE_GAME_LIBRARY_DIR': '/unexpected/lib'}, '/verified/lib')
        with self.assertRaisesRegex(RuntimeError, 'differs'):
            launch.game_environment({'CABOOSE_GAME_LIBRARY_DIR': '/unexpected/lib'}, None)


if __name__ == '__main__':
    unittest.main()
