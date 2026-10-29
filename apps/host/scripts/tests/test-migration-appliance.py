#!/usr/bin/env python3
import hashlib
import importlib.util
from pathlib import Path
import tempfile
import subprocess
import signal
import unittest
from unittest.mock import Mock, patch

path = Path(__file__).resolve().parents[2] / 'src/migration_appliance.py'
spec = importlib.util.spec_from_file_location('migration_appliance', path)
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)


class ApplianceTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.clone = self.root / 'clone.raw'
        self.clone.write_bytes(b'guest image')
        self.output = self.root / 'system.erofs'

    def test_timeout_terminates_private_process_group(self):
        process = Mock()
        process.pid = 12345
        process.wait.side_effect = [subprocess.TimeoutExpired('guestfish', 1), 0]
        process.poll.return_value = None
        with patch.object(m.subprocess, 'Popen', return_value=process), patch.object(m.os, 'killpg') as killpg:
            with self.assertRaisesRegex(m.ApplianceError, 'timed out'):
                m._guestfish(['/guestfish'], {}, self.root / 'log', 1, 1024)
        killpg.assert_called_once_with(12345, signal.SIGTERM)
        self.assertEqual(process.wait.call_count, 2)

    def test_pack_uses_readonly_clone_and_network_disabled_vm(self):
        calls = []
        def guestfish(args, env, log, timeout, size_limit):
            calls.append((args, env))
            self.output.write_bytes(b'image')
        with patch.object(m, 'trusted_executable', side_effect=lambda p: Path(p)), \
             patch.object(m, 'dependencies', return_value={}), patch.object(m, '_guestfish', guestfish):
            m.pack_system_image(self.clone, self.output, self.root)
        args, env = calls[0]
        self.assertEqual(args[1:5], ['add-drive', str(self.clone.resolve()), 'readonly:true', 'format:raw'])
        i = args.index('set-network')
        self.assertEqual(args[i + 1], 'false')
        self.assertEqual(env['LIBGUESTFS_BACKEND'], 'direct')
        self.assertIn('download', args)
        self.assertEqual(self.output.read_bytes(), b'image')

    def test_failure_removes_only_partial_output(self):
        def fail(*args):
            self.output.write_bytes(b'partial')
            raise m.ApplianceError('failure')
        with patch.object(m, 'trusted_executable', side_effect=lambda p: Path(p)), \
             patch.object(m, 'dependencies', return_value={}), patch.object(m, '_guestfish', fail):
            with self.assertRaisesRegex(m.ApplianceError, 'failure'):
                m.pack_system_image(self.clone, self.output, self.root)
        self.assertFalse(self.output.exists())
        self.assertEqual(self.clone.read_bytes(), b'guest image')

    def test_rejects_nonprivate_work_directory(self):
        import os
        os.chmod(self.root, 0o755)
        with self.assertRaisesRegex(m.ApplianceError, 'private'):
            m.pack_system_image(self.clone, self.output, self.root)
        self.assertFalse(self.output.exists())

    def test_rejects_insufficient_space_before_launch(self):
        class Space:
            f_bavail = 1
            f_frsize = 4096
        with patch.object(m.os, 'statvfs', return_value=Space()):
            with self.assertRaisesRegex(m.ApplianceError, 'Insufficient free space'):
                m.pack_system_image(self.clone, self.output, self.root)
        self.assertFalse(self.output.exists())

    def test_kernel_matching_uses_trusted_appliance_and_exact_hash(self):
        kernel = self.root / 'kernel'
        kernel.write_bytes(b'legacy kernel')
        digest = hashlib.sha256(kernel.read_bytes()).hexdigest()
        calls = []
        def guestfish(args, env, log, timeout, size_limit):
            calls.append((args, env))
            return f'{digest}  /sysroot/boot/vmlinuz-6.12.0-test\n'
        with patch.object(m, 'trusted_executable', side_effect=lambda p: Path(p)), patch.object(m, '_guestfish', guestfish):
            self.assertEqual(m.matching_kernel(self.clone, kernel, self.root), '6.12.0-test')
        self.assertIn('readonly:true', calls[0][0])
        self.assertEqual(calls[0][0][calls[0][0].index('set-network') + 1], 'false')

    def test_kernel_matching_rejects_unmatched_or_ambiguous_kernels(self):
        kernel = self.root / 'kernel'
        kernel.write_bytes(b'legacy kernel')
        digest = hashlib.sha256(kernel.read_bytes()).hexdigest()
        for output in ('', f'{digest}  /sysroot/boot/vmlinuz-6.1\n{digest}  /sysroot/boot/vmlinuz-6.2\n'):
            with self.subTest(output=output), patch.object(m, 'trusted_executable', side_effect=lambda p: Path(p)), patch.object(m, '_guestfish', return_value=output):
                with self.assertRaisesRegex(m.ApplianceError, 'exactly one'):
                    m.matching_kernel(self.clone, kernel, self.root)

    def test_final_layout_uses_appliance_apis_without_guest_execution(self):
        hook = self.root / 'hook'
        initrd = self.root / 'initrd'
        hook.write_bytes(b'hook')
        initrd.write_bytes(b'initrd')
        calls = []
        def guestfish(args, env, log, timeout, size_limit):
            calls.append(args)
            return ''
        with patch.object(m, 'trusted_executable', side_effect=lambda p: Path(p)), patch.object(m, '_guestfish', guestfish):
            m.prepare_system_disk(self.clone, '6.12.0-test', hook, initrd, self.root)
        args = calls[0]
        self.assertNotIn('sh', [arg for i, arg in enumerate(args) if i == 0 or args[i - 1] != 'debug'])
        self.assertIn('rm-r', args)
        self.assertEqual(args[args.index('set-network') + 1], 'false')

    def test_hooks_use_only_independent_clone_and_fresh_readonly_download(self):
        hook_clone = self.root / 'hook.raw'
        hook_clone.write_bytes(b'guest copy')
        hook = self.root / 'hook'
        hook.write_bytes(b'hook')
        output = self.root / 'initrd'
        calls = []
        def guestfish(args, env, log, timeout, size_limit):
            calls.append((args, env))
            if 'download' in args:
                output.write_bytes(b'initrd')
            else:
                hook_clone.write_bytes(b'untrusted hook modified its disk')
            return ''
        with patch.object(m, 'trusted_executable', side_effect=lambda p: Path(p)), patch.object(m, '_guestfish', guestfish):
            m.rebuild_initramfs(hook_clone, self.clone, '6.12.0-test', hook, output, self.root)
        self.assertEqual(len(calls), 2)
        for args, env in calls:
            self.assertIn(str(hook_clone.resolve()), args)
            self.assertNotIn(str(self.clone.resolve()), args)
            self.assertEqual(args[args.index('set-network') + 1], 'false')
            self.assertEqual(env['LIBGUESTFS_BACKEND'], 'direct')
        self.assertIn('sh', calls[0][0])
        self.assertIn('readonly:true', calls[1][0])
        self.assertEqual(output.read_bytes(), b'initrd')
        self.assertEqual(self.clone.read_bytes(), b'guest image')

    def test_rejects_shell_metacharacters_in_kernel_version(self):
        scratch = self.root / 'hook.raw'
        scratch.write_bytes(b'copy')
        hook = self.root / 'hook'
        hook.write_bytes(b'hook')
        for version in ('-danger', '6.1;touch-pwned', '$(id)', '~root'):
            with self.subTest(version=version), self.assertRaises(m.ApplianceError):
                m.rebuild_initramfs(scratch, self.clone, version, hook, self.root / 'initrd', self.root)

    def test_rejects_nonindependent_hook_disk(self):
        hook = self.root / 'hook'
        hook.write_bytes(b'hook')
        same = self.root / 'same.raw'
        import os
        os.link(self.clone, same)
        with self.assertRaisesRegex(m.ApplianceError, 'independent'):
            m.rebuild_initramfs(same, self.clone, '6.12.0-test', hook, self.root / 'initrd', self.root)

    def test_rejects_symlink_input_and_existing_output(self):
        link = self.root / 'link.raw'
        link.symlink_to(self.clone)
        with self.assertRaises(m.ApplianceError):
            m.pack_system_image(link, self.output, self.root)
        self.output.write_bytes(b'keep')
        with self.assertRaises(m.ApplianceError):
            m.pack_system_image(self.clone, self.output, self.root)
        self.assertEqual(self.output.read_bytes(), b'keep')


if __name__ == '__main__':
    unittest.main()
