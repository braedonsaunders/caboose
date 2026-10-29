#!/usr/bin/env python3
import importlib.util
import json
from pathlib import Path
import sys
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import Mock, patch

source = Path(__file__).resolve().parents[2] / 'src'
sys.path.insert(0, str(source))
spec = importlib.util.spec_from_file_location('migration_appliance_guard', source / 'migration_appliance_guard.py')
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)


class GuardTests(unittest.TestCase):
    def test_refuses_to_launch_after_parent_has_already_exited(self):
        with tempfile.TemporaryDirectory() as path:
            root = Path(path)
            journal = root / 'journal'
            journal.write_text(json.dumps({'version': 1, 'operation': 'prepare', 'computer': 'owner', 'phase': 'reserved'}))
            argv = ['guard', str(journal), 'owner', '10', '4096', str(root), '987', '/usr/bin/guestfish', 'add-drive', str(root / 'disk')]
            with patch.object(sys, 'argv', argv), patch.object(m.os, 'getppid', return_value=1), patch.object(m.subprocess, 'Popen') as spawn:
                with self.assertRaisesRegex(RuntimeError, 'parent exited'):
                    m.main()
            spawn.assert_not_called()
            self.assertEqual(json.loads(journal.read_text())['phase'], 'reserved')

    def test_records_running_before_launch_and_idle_after_cleanup(self):
        with tempfile.TemporaryDirectory() as path:
            root = Path(path)
            journal = root / 'journal'
            journal.write_text(json.dumps({'version': 1, 'operation': 'prepare', 'computer': 'owner', 'phase': 'reserved'}))
            real_read, real_stat = Path.read_text, m.os.stat
            def read(p, *args, **kwargs):
                if str(p) == '/proc/sys/kernel/random/boot_id':
                    return 'test-boot\n'
                return real_read(p, *args, **kwargs)
            def stat(p, *args, **kwargs):
                if str(p) == '/proc/self/ns/pid':
                    return SimpleNamespace(st_ino=42)
                return real_stat(p, *args, **kwargs)
            child = Mock()
            child.poll.return_value = 0
            child.returncode = 0
            child.wait.return_value = 0
            events = []
            def spawn(*args, **kwargs):
                self.assertEqual(json.loads(journal.read_text())['phase'], 'running')
                events.append('spawn')
                return child
            def drain(group):
                self.assertEqual(json.loads(journal.read_text())['phase'], 'running')
                events.append('drain')
            libc = Mock()
            libc.prctl.return_value = 0
            argv = ['guard', str(journal), 'owner', '10', '4096', str(root), '987', '/usr/bin/guestfish', 'add-drive', str(root / 'disk')]
            with patch.object(sys, 'argv', argv), patch.object(Path, 'read_text', read), \
                 patch.object(m.os, 'stat', stat), patch.object(m.os, 'getpid', return_value=123), \
                 patch.object(m.os, 'getpgrp', return_value=123), patch.object(m.os, 'getppid', return_value=987), patch.object(m.ctypes, 'CDLL', return_value=libc), \
                 patch.object(m.signal, 'signal'), patch.object(m.subprocess, 'Popen', side_effect=spawn), \
                 patch.object(m, 'terminate_members', side_effect=drain), patch.object(m, 'references', return_value=set()), \
                 patch.object(m.os, 'waitpid', side_effect=ChildProcessError):
                self.assertEqual(m.main(), 0)
            self.assertEqual(events, ['spawn', 'drain'])
            record = json.loads(journal.read_text())
            self.assertEqual(record['phase'], 'idle')
            self.assertEqual(record['process_group'], 123)
            self.assertEqual(record['appliance_disks'], [str(root / 'disk')])

    def test_parent_exit_drains_appliance_before_releasing_intent(self):
        with tempfile.TemporaryDirectory() as path:
            root = Path(path)
            journal = root / 'journal'
            journal.write_text(json.dumps({'version': 1, 'operation': 'prepare', 'computer': 'owner', 'phase': 'reserved'}))
            real_read, real_stat = Path.read_text, m.os.stat
            def read(p, *args, **kwargs):
                return 'test-boot\n' if str(p) == '/proc/sys/kernel/random/boot_id' else real_read(p, *args, **kwargs)
            def stat(p, *args, **kwargs):
                return SimpleNamespace(st_ino=42) if str(p) == '/proc/self/ns/pid' else real_stat(p, *args, **kwargs)
            child = Mock()
            child.poll.return_value = None
            child.wait.return_value = -15
            libc = Mock()
            libc.prctl.return_value = 0
            argv = ['guard', str(journal), 'owner', '10', '4096', str(root), '987', '/usr/bin/guestfish', 'add-drive', str(root / 'disk')]
            with patch.object(sys, 'argv', argv), patch.object(Path, 'read_text', read), \
                 patch.object(m.os, 'stat', stat), patch.object(m.os, 'getpid', return_value=123), \
                 patch.object(m.os, 'getpgrp', return_value=123), patch.object(m.os, 'getppid', side_effect=[987, 987, 11, 11]), \
                 patch.object(m.ctypes, 'CDLL', return_value=libc), patch.object(m.signal, 'signal'), \
                 patch.object(m.subprocess, 'Popen', return_value=child), patch.object(m, 'terminate_members') as drain, \
                 patch.object(m, 'references', return_value=set()), patch.object(m.os, 'waitpid', side_effect=ChildProcessError):
                self.assertEqual(m.main(), 1)
            drain.assert_called_once_with(123)
            self.assertEqual(json.loads(journal.read_text())['phase'], 'idle')

    def test_unverified_remaining_reference_leaves_running_journal(self):
        with tempfile.TemporaryDirectory() as path:
            root = Path(path)
            journal = root / 'journal'
            journal.write_text(json.dumps({'version': 1, 'operation': 'prepare', 'computer': 'owner', 'phase': 'reserved'}))
            real_read, real_stat = Path.read_text, m.os.stat
            def read(p, *args, **kwargs):
                return 'test-boot\n' if str(p) == '/proc/sys/kernel/random/boot_id' else real_read(p, *args, **kwargs)
            def stat(p, *args, **kwargs):
                return SimpleNamespace(st_ino=42) if str(p) == '/proc/self/ns/pid' else real_stat(p, *args, **kwargs)
            child = Mock()
            child.poll.return_value = 0
            child.returncode = 0
            child.wait.return_value = 0
            libc = Mock()
            libc.prctl.return_value = 0
            argv = ['guard', str(journal), 'owner', '10', '4096', str(root), '987', '/usr/bin/guestfish', 'add-drive', str(root / 'disk')]
            with patch.object(sys, 'argv', argv), patch.object(Path, 'read_text', read), \
                 patch.object(m.os, 'stat', stat), patch.object(m.os, 'getpid', return_value=123), \
                 patch.object(m.os, 'getpgrp', return_value=123), patch.object(m.os, 'getppid', return_value=987), patch.object(m.ctypes, 'CDLL', return_value=libc), \
                 patch.object(m.signal, 'signal'), patch.object(m.subprocess, 'Popen', return_value=child), \
                 patch.object(m, 'terminate_members'), patch.object(m, 'references', return_value={456}), \
                 patch.object(m.os, 'waitpid', side_effect=ChildProcessError):
                with self.assertRaisesRegex(RuntimeError, 'still references'):
                    m.main()
            self.assertEqual(json.loads(journal.read_text())['phase'], 'running')


if __name__ == '__main__':
    unittest.main()
