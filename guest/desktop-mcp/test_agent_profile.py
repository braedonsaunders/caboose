import ast
import concurrent.futures
import importlib.util
import os
from pathlib import Path
import tempfile
import subprocess
import sys
import unittest

spec = importlib.util.spec_from_file_location('profile', Path(__file__).with_name('agent-profile.py'))
profile = importlib.util.module_from_spec(spec)
spec.loader.exec_module(profile)


class Profiles(unittest.TestCase):
    def test_concurrent_start_persistence_and_owner_untouched(self):
        with tempfile.TemporaryDirectory() as directory:
            owner = Path(directory)
            (owner / '.config').mkdir()
            (owner / '.config/Cookies').write_bytes(b'synthetic-owner-sign-in')
            with concurrent.futures.ThreadPoolExecutor(max_workers=8) as pool:
                results = list(pool.map(profile.environment, [owner] * 16))
            self.assertTrue(all(result == results[0] for result in results))
            home = Path(results[0]['HOME'])
            cookie = home / '.config/Cookies'
            self.assertFalse(cookie.exists())
            cookie.write_bytes(b'synthetic-agent-sign-in')
            # Simulate stale initialization temp and browser lock after crash.
            (home.parent / '.version-crashed').write_text('partial')
            (home / '.config/SingletonLock').symlink_to('synthetic-host-999999')
            self.assertEqual(profile.environment(owner), results[0])
            self.assertEqual(cookie.read_bytes(), b'synthetic-agent-sign-in')
            # Adopt an unversioned agent-owned directory without replacing sign-ins.
            (home.parent / 'version').unlink()
            self.assertEqual(profile.environment(owner), results[0])
            self.assertEqual(cookie.read_bytes(), b'synthetic-agent-sign-in')
            self.assertTrue((home / '.config/SingletonLock').is_symlink())
            self.assertEqual((owner / '.config/Cookies').read_bytes(), b'synthetic-owner-sign-in')

    def test_kernel_releases_initialization_lock_after_crash(self):
        with tempfile.TemporaryDirectory() as directory:
            env = profile.environment(directory)
            root = Path(env['HOME']).parent
            subprocess.run([sys.executable, '-c',
                'import fcntl,os,sys; fd=os.open(sys.argv[1],os.O_RDWR); fcntl.flock(fd,fcntl.LOCK_EX); os._exit(0)',
                str(root / '.init.lock')], check=True, timeout=5)
            self.assertEqual(profile.environment(directory), env)

    def test_gui_command_rejects_profile_redirection_and_preserves_arguments(self):
        for app in profile.GUI_APPS:
            self.assertEqual(profile.gui_command(app, ['https://example.test/a b']),
                             ['/usr/bin/' + app, 'https://example.test/a b'])
            for args in [['--user-data-dir=/synthetic-owner'], ['-P', 'owner'], ['--profile', '/owner']]:
                with self.assertRaises(RuntimeError):
                    profile.gui_command(app, args)

    def test_runner_keeps_cli_auth_home_after_gui_environment(self):
        source = (Path(__file__).resolve().parents[2] / 'apps/host/src/agents.ts').read_text()
        launch = source.split('const LAUNCH = [', 1)[1].split('\n]', 1)[0]
        commands = [ast.literal_eval(line.strip().removesuffix(',')) for line in launch.splitlines()
                    if line.strip().startswith(("'unset ", "'export HOME="))]
        self.assertEqual(len(commands), 2)
        initial = {'HOME': '/synthetic-agent', 'XDG_CONFIG_HOME': '/synthetic-agent/.config',
                   'XDG_DATA_HOME': '/synthetic-agent/.local/share', 'CABOOSE_SEAT': 'agent'}
        output = subprocess.check_output(['/bin/sh', '-c', '; '.join(commands) + '; /usr/bin/env'], env=initial, text=True)
        values = dict(line.split('=', 1) for line in output.splitlines())
        self.assertEqual(values['HOME'], '/home/caboose')
        self.assertNotIn('XDG_CONFIG_HOME', values)
        self.assertNotIn('XDG_DATA_HOME', values)
        self.assertNotIn('CABOOSE_SEAT', values)
        self.assertTrue(values['PATH'].startswith('/usr/local/libexec/caboose-agent-seat-bin:'))

    def test_unknown_version_and_symlinks_fail_without_rewriting(self):
        with tempfile.TemporaryDirectory() as directory:
            values = profile.environment(directory)
            home = Path(values['HOME'])
            version = home.parent / 'version'
            version.write_text('2\n')
            with self.assertRaises(RuntimeError):
                profile.environment(directory)
            self.assertEqual(version.read_text(), '2\n')
            version.write_text('1\n')
            (home / '.config').rmdir()
            (home / '.config').symlink_to(directory)
            with self.assertRaises(RuntimeError):
                profile.environment(directory)


if __name__ == '__main__':
    unittest.main()
