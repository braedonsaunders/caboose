import importlib.util
import pathlib
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('caboose_template', pathlib.Path(__file__).with_name('caboose-template.py'))
helper = importlib.util.module_from_spec(spec)
spec.loader.exec_module(helper)


class TemplateHelperTest(unittest.TestCase):
    def test_prepare_refuses_running_users_without_writing_marker(self):
        with tempfile.TemporaryDirectory() as directory:
            marker = pathlib.Path(directory) / 'ready'
            with patch.object(helper, 'READY', marker), patch.object(helper, 'template_boot'), patch.object(helper, 'run'), patch.object(helper, 'user_processes', return_value=['123']):
                with self.assertRaisesRegex(RuntimeError, 'User processes'):
                    helper.prepare()
                self.assertFalse(marker.exists())

    def test_prepare_compacts_and_warms_memory_before_writing_ready_marker(self):
        with tempfile.TemporaryDirectory() as directory:
            marker = pathlib.Path(directory) / 'ready'
            with patch.object(helper, 'READY', marker), patch.object(helper, 'template_boot'), patch.object(helper, 'run'), patch.object(helper, 'user_processes', return_value=[]), patch.object(helper, 'compact_and_warm_template_memory', return_value=4096) as compact_warm:
                helper.prepare()
                compact_warm.assert_called_once_with()
                self.assertEqual(marker.read_text(), 'prepared\n')

    def test_warm_shared_pages_faults_libraries_and_caps_large_binaries(self):
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            lib_dir = root / 'lib' / 'x86_64-linux-gnu'
            bin_dir = root / 'usr' / 'bin'
            etc_dir = root / 'etc'
            lib_dir.mkdir(parents=True)
            bin_dir.mkdir(parents=True)
            etc_dir.mkdir(parents=True)
            (lib_dir / 'libc.so.6').write_bytes(b'c' * 1024)
            (lib_dir / 'libgtk-3.so.0').write_bytes(b'g' * 2048)
            (bin_dir / 'python3').write_bytes(b'p' * 512)
            (bin_dir / 'node').write_bytes(b'n' * 8192)
            (etc_dir / 'ld.so.cache').write_bytes(b'l' * 256)
            warmed = helper.warm_shared_pages(root, max_file_bytes=4096)
            self.assertEqual(warmed, 1024 + 2048 + 512 + 4096 + 256)

    def test_compact_and_warm_template_memory_purges_scratch_runs_memory_setup_and_warms_pages(self):
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            for rel in ('var/log/journal/boot1', 'tmp/sub', 'var/tmp', 'var/cache/apt/archives', 'proc/sys/vm', 'usr/local/libexec', 'etc'):
                (root / rel).mkdir(parents=True, exist_ok=True)
            (root / 'var/log/journal/boot1/system.journal').write_text('log')
            (root / 'tmp/scratch.txt').write_text('scratch')
            (root / 'tmp/sub/nested.txt').write_text('nested')
            (root / 'var/tmp/temp.txt').write_text('temp')
            (root / 'var/cache/apt/archives/pkg.deb').write_text('deb')
            (root / 'usr/local/libexec/caboose-memory').write_text('#!/bin/sh\n')
            (root / 'etc/ld.so.cache').write_bytes(b'x' * 128)
            with patch.object(helper.subprocess, 'run') as subproc_run:
                warmed = helper.compact_and_warm_template_memory(root)
            self.assertEqual(warmed, 128)
            self.assertFalse((root / 'var/log/journal/boot1').exists())
            self.assertFalse((root / 'tmp/scratch.txt').exists())
            self.assertFalse((root / 'tmp/sub').exists())
            self.assertFalse((root / 'var/tmp/temp.txt').exists())
            self.assertFalse((root / 'var/cache/apt/archives/pkg.deb').exists())
            self.assertEqual((root / 'proc/sys/vm/drop_caches').read_text(), '3\n')
            self.assertEqual((root / 'proc/sys/vm/compact_memory').read_text(), '1\n')
            commands = [call.args[0] for call in subproc_run.call_args_list]
            self.assertIn(['fstrim', str(root)], commands)
            self.assertIn([str(root / 'usr/local/libexec/caboose-memory'), 'setup'], commands)

    def test_agent_restart_requires_a_new_process_identity(self):
        with patch.object(helper, 'agent_identity', return_value='123:456'):
            with self.assertRaisesRegex(RuntimeError, 'has not restarted'):
                helper.check_agent('123:456')
            helper.check_agent('123:455')
            with self.assertRaisesRegex(RuntimeError, 'Invalid prior'):
                helper.check_agent('invalid')

    def test_reprobe_requires_exactly_one_device(self):
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            driver = root / 'virtio_rng'
            driver.mkdir()
            (driver / 'unbind').touch()
            (driver / 'bind').touch()
            with self.assertRaisesRegex(RuntimeError, 'exactly one'):
                helper.rebind_driver('virtio_rng', root)
            (driver / 'virtio0').touch()
            helper.rebind_driver('virtio_rng', root)
            self.assertEqual((driver / 'unbind').read_text(), 'virtio0')
            self.assertEqual((driver / 'bind').read_text(), 'virtio0')
            (driver / 'virtio1').touch()
            with self.assertRaisesRegex(RuntimeError, 'exactly one'):
                helper.rebind_driver('virtio_rng', root)

    def test_activate_refuses_to_start_user_services_before_reset(self):
        with tempfile.TemporaryDirectory() as directory:
            marker = pathlib.Path(directory) / 'initialized'
            marker.write_text('incorrect\n')
            with patch.object(helper, 'INITIALIZED', marker), patch.object(helper, 'template_boot'), patch.object(helper, 'run') as run:
                with self.assertRaisesRegex(RuntimeError, 'not been reinitialized'):
                    helper.activate()
                run.assert_not_called()

    def test_reinitialize_rejects_invalid_identity_before_reading_entropy(self):
        with tempfile.TemporaryDirectory() as directory:
            marker = pathlib.Path(directory) / 'ready'
            marker.write_text('prepared\n')
            with patch.object(helper, 'READY', marker), patch.object(helper, 'template_boot'), patch.object(helper, 'user_processes', return_value=[]), patch.object(helper, 'hardware_random') as random:
                with self.assertRaisesRegex(RuntimeError, 'MAC'):
                    helper.reinitialize('01:00:00:00:00:01', 10)
                with self.assertRaisesRegex(RuntimeError, 'CID'):
                    helper.reinitialize('02:00:00:00:00:01', 2)
                random.assert_not_called()
                self.assertTrue(marker.exists())


if __name__ == '__main__':
    unittest.main()
