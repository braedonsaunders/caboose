#!/usr/bin/env python3
import hashlib
import importlib.util
import json
import os
import subprocess
from pathlib import Path
import tempfile
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

    def run_mount_script(self, filesystem, readonly):
        # Execute the actual generated appliance shell with harmless tool
        # substitutes. Verify selection and fail-closed behavior, not just text.
        bindir = self.root / 'bin'
        bindir.mkdir(exist_ok=True)
        probe = bindir / 'blkid'
        probe.write_text('#!/bin/sh\nprintf "%s\\n" "$TEST_FILESYSTEM"\n')
        mount = bindir / 'mount'
        mount.write_text('#!/bin/sh\nprintf "%s\\n" "$@"\n')
        probe.chmod(0o700)
        mount.chmod(0o700)
        return subprocess.run(['/bin/sh', '-c', m._mount_root_script(readonly)],
                              env={**os.environ, 'PATH': str(bindir), 'TEST_FILESYSTEM': filesystem},
                              capture_output=True, text=True, timeout=5)

    def test_mounts_both_filesystems_with_correct_replay_and_compression(self):
        for filesystem, readonly, options in (
                ('ext4', True, 'ro,noload'), ('btrfs', True, 'ro,rescue=nologreplay'),
                ('ext4', False, 'rw'), ('btrfs', False, 'rw,compress-force=zstd:1')):
            with self.subTest(filesystem=filesystem, readonly=readonly):
                result = self.run_mount_script(filesystem, readonly)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(result.stdout.splitlines(),
                                 ['-t', filesystem, '-o', options, '/dev/sda3', '/sysroot'])

    def test_unknown_filesystem_never_mounts(self):
        for filesystem in ('', 'xfs', 'ext4\nbtrfs', '$(touch bad)'):
            with self.subTest(filesystem=filesystem):
                result = self.run_mount_script(filesystem, False)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(result.stdout, '')

    def test_discard_is_only_enabled_for_writable_reclaim(self):
        for readonly in (True, False):
            args = m._disk_commands('/guestfish', self.clone, readonly)
            self.assertNotIn('discard:enable', args)
        with self.assertRaisesRegex(m.ApplianceError, 'read-only'):
            m._disk_commands('/guestfish', self.clone, True, discard=True)

    def test_appliance_launch_requires_durable_guard(self):
        with self.assertRaisesRegex(m.ApplianceError, 'durable preparation guard'):
            m._guestfish(['/guestfish'], {}, self.root / 'log', 1, 1024, None)

    def test_guard_inherits_host_and_disk_descriptors(self):
        journal = self.root / 'journal'
        journal.write_text(json.dumps({'operation': 'prepare', 'computer': 'owner', 'phase': 'idle'}))
        process = Mock()
        process.wait.return_value = 0
        process.poll.return_value = 0
        guard = {'journal': journal, 'computer': 'owner', 'fds': (7, 8)}
        with patch.object(m.subprocess, 'Popen', return_value=process) as spawn:
            m._guestfish(['/guestfish'], {}, self.root / 'log', 1, 1024, guard)
        self.assertEqual(spawn.call_args.kwargs['pass_fds'], (7, 8))
        self.assertTrue(spawn.call_args.kwargs['start_new_session'])
        self.assertIn('migration_appliance_guard.py', spawn.call_args.args[0][1])

    def test_pack_uses_readonly_clone_and_network_disabled_vm(self):
        calls = []
        scripts = []
        def guestfish(args, env, log, timeout, size_limit, guard):
            if log.name == 'measure.log':
                return 'CABOOSE_TREE_V1 4096 2 0\n'
            calls.append((args, env))
            scripts.append(next(log.parent.glob('pack.sh')).read_text())
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
        self.assertTrue(any('/sysroot/var/lib/caboose/system-overlay' in arg for arg in args))
        self.assertEqual(self.output.read_bytes(), b'image')
        self.assertIn('-zlz4hc,12 -C65536 -E noinline_data', scripts[0])
        self.assertNotIn('-xdev', scripts[0])
        self.assertIn('/tmp/caboose-fsck /sysroot/tmp/system.erofs', scripts[0])

    def test_failure_removes_only_partial_output(self):
        def fail(*args):
            if args[2].name == 'measure.log':
                return 'CABOOSE_TREE_V1 4096 2 0\n'
            self.output.write_bytes(b'partial')
            raise m.ApplianceError('failure')
        with patch.object(m, 'trusted_executable', side_effect=lambda p: Path(p)), \
             patch.object(m, 'dependencies', return_value={}), patch.object(m, '_guestfish', fail):
            with self.assertRaisesRegex(m.ApplianceError, 'failure'):
                m.pack_system_image(self.clone, self.output, self.root)
        self.assertFalse(self.output.exists())
        self.assertEqual(self.clone.read_bytes(), b'guest image')

    def test_measurement_accounts_logical_content_entries_and_xattrs(self):
        # Identical physical occupancy is irrelevant: compressed or sparse
        # files with larger logical sizes need larger expanded staging/output.
        small = m._measured_scratch('CABOOSE_TREE_V1 4096 2 0\n')
        self.assertEqual(m._measured_scratch('\n\nCABOOSE_TREE_V1 4096 2 0\n\n'), small)
        large = m._measured_scratch(f'CABOOSE_TREE_V1 {100 * 1024 ** 3} 2 0\n')
        self.assertEqual(large - small, 2 * (100 * 1024 ** 3 - 4096))
        self.assertEqual(m._measured_scratch('CABOOSE_TREE_V1 4096 3 1000\n') - small,
                         2 * (m._ENTRY_ALLOWANCE + 1000))

    def test_invalid_and_excessive_measurements_fail_closed(self):
        for result in ('', '4096 2 0', 'CABOOSE_TREE_V1 -1 2 0\n',
                       'CABOOSE_TREE_V1 1 1 0\n', 'CABOOSE_TREE_V1 1 1000001 0\n',
                       'CABOOSE_TREE_V1 1099511627777 2 0\n',
                       'CABOOSE_TREE_V1 1099511627776 2 0\n',
                       'CABOOSE_TREE_V1 1 2 16777217\n',
                       'CABOOSE_TREE_V1 1 2 0\nnoise\n'):
            with self.subTest(result=result), self.assertRaises(m.ApplianceError):
                m._measured_scratch(result)

    def test_measured_pack_gate_is_independent_of_disk_capacity(self):
        with self.clone.open('wb') as disk:
            disk.truncate(60 * 1024 ** 3)
        calls = []
        def guestfish(args, env, log, timeout, limit, guard):
            calls.append((args, timeout, limit))
            self.assertEqual(args[2], str(self.clone.resolve()))
            self.assertIn('readonly:true', args)
            if log.name == 'measure.log':
                self.assertNotIn('add-drive', args[3:])
                return 'CABOOSE_TREE_V1 1073741824 1000 1000\n'
            self.output.write_bytes(b'image')
        budget = m._measured_scratch('CABOOSE_TREE_V1 1073741824 1000 1000\n')
        with patch.object(m, 'trusted_executable', side_effect=Path), \
             patch.object(m, 'dependencies', return_value={}), \
             patch.object(m, '_guestfish', guestfish), \
             patch.object(m, '_require_space') as space:
            m.pack_system_image(self.clone, self.output, self.root)
        self.assertEqual(calls[0][1:], (600, m._READONLY_LIMIT))
        self.assertEqual(calls[1][2], budget)
        self.assertEqual(space.call_args.args, (self.root.resolve(), budget * 4 + m._READONLY_LIMIT))
        self.assertLess(budget * 4 + m._READONLY_LIMIT, 32 * 1024 ** 3)

    def test_failed_measurement_never_packs(self):
        for result in ('malformed', m.ApplianceError('measurement failed')):
            with self.subTest(result=result), \
                 patch.object(m, 'trusted_executable', side_effect=Path), \
                 patch.object(m, 'dependencies', return_value={}), \
                 patch.object(m, '_guestfish', side_effect=[result]) as fish:
                with self.assertRaises(m.ApplianceError):
                    m.pack_system_image(self.clone, self.output, self.root)
                self.assertEqual(fish.call_count, 1)
                self.assertFalse(self.output.exists())
                self.assertFalse(list(self.root.glob('.migration-*')))

    def test_changed_clone_or_unverified_measurement_never_packs(self):
        def mutate(*args):
            self.clone.write_bytes(b'changed content')
            return 'CABOOSE_TREE_V1 4096 2 0\n'
        with patch.object(m, 'trusted_executable', side_effect=Path), \
             patch.object(m, 'dependencies', return_value={}), \
             patch.object(m, '_guestfish', side_effect=mutate) as fish:
            with self.assertRaisesRegex(m.ApplianceError, 'clone changed'):
                m.pack_system_image(self.clone, self.output, self.root)
            self.assertEqual(fish.call_count, 1)
        with patch.object(m, 'trusted_executable', side_effect=Path), \
             patch.object(m, 'dependencies', return_value={}), \
             patch.object(m, '_measure_tree', return_value=m._READONLY_LIMIT) as measure, \
             patch.object(m, '_guard_quiescent', side_effect=[True, False]), \
             patch.object(m, '_guestfish') as fish:
            with self.assertRaisesRegex(m.ApplianceError, 'quiescent'):
                m.pack_system_image(self.clone, self.output, self.root)
            measure.assert_called_once()
            fish.assert_not_called()
        self.assertFalse(self.output.exists())

    def test_insufficient_measured_space_never_packs(self):
        with patch.object(m, 'trusted_executable', side_effect=Path), \
             patch.object(m, 'dependencies', return_value={}), \
             patch.object(m, '_guestfish', return_value='CABOOSE_TREE_V1 107374182400 2 0\n') as fish, \
             patch.object(m.os, 'statvfs', return_value=Mock(f_bavail=20, f_frsize=1024 ** 3)):
            with self.assertRaisesRegex(m.ApplianceError, 'Insufficient'):
                m.pack_system_image(self.clone, self.output, self.root)
            self.assertEqual(fish.call_count, 1)
            self.assertFalse(self.output.exists())

    def run_measurement_script(self, sizes, *, find_status=0, xattrs=b'', xattr_status=0):
        # Execute trusted shell/awk logic locally with a synthetic find and
        # xattr tool. No Linux filesystem, appliance, mount or guest code runs.
        bindir = self.root / 'measure-bin'
        bindir.mkdir(exist_ok=True)
        source = self.root / 'sizes'
        source.write_text(sizes)
        attrs = self.root / 'attrs'
        attrs.write_bytes(xattrs)
        find = bindir / 'find'
        find.write_text('#!/bin/sh\n/bin/cat "' + str(source) + '"\nexit ' + str(find_status) + '\n')
        find.chmod(0o700)
        getter = self.root / 'getter'
        getter.write_text('#!/bin/sh\n/bin/cat "' + str(attrs) + '"\nexit ' + str(xattr_status) + '\n')
        getter.chmod(0o700)
        script = m._measurement_script().replace(m._pack_preflight(), 'set -eu')
        script = script.replace('/tmp/caboose-awk', '/usr/bin/awk')
        script = script.replace('/tmp/caboose-getfattr', str(getter))
        script = script.replace('/tmp/caboose-', str(self.root / 'caboose-'))
        return subprocess.run(['/bin/sh', '-c', script],
                              env={**os.environ, 'PATH': str(bindir) + ':/usr/bin:/bin'},
                              capture_output=True, text=True, timeout=5)

    def test_measurement_shell_counts_each_path_and_xattr_dump(self):
        # Duplicate sizes stand for hardlinked/reflinked paths: both count.
        result = self.run_measurement_script('4096\n4096\n107374182400\n107374182400\n', xattrs=b'0x1234\n')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, 'CABOOSE_TREE_V1 214748372992 4 7\n')
        script = m._measurement_script()
        self.assertIn('find /sysroot/usr /sysroot/opt -printf "%s', script)
        self.assertNotIn('-xdev', script)
        self.assertIn('-R -P -h', script)
        self.assertIn('ulimit -f', script)

    def test_failed_or_excessive_xattr_scan_never_reports_success(self):
        for content, status in [(b'partial', 1), (b'x' * (m._MAX_XATTR_DUMP + 1), 0)]:
            with self.subTest(length=len(content), status=status):
                result = self.run_measurement_script('4096\n4096\n', xattrs=content, xattr_status=status)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(result.stdout, '')

    def test_measurement_shell_rejects_partial_failed_or_overflowed_scan(self):
        for sizes, status in [('4096\n4096\n', 1), ('4096\nbad\n', 0),
                              ('1099511627777\n1\n', 0), ('1\n', 0),
                              ('0\n' * 1000001, 0)]:
            with self.subTest(status=status, length=len(sizes)):
                result = self.run_measurement_script(sizes, find_status=status)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(result.stdout, '')

    def test_unverified_appliance_files_are_retained(self):
        journal = self.root / 'journal'
        journal.write_text(json.dumps({'operation': 'prepare', 'computer': 'owner', 'phase': 'running'}))
        guard = {'journal': journal, 'computer': 'owner'}
        with m._appliance_directory(self.root, 'appliance-', guard) as work:
            (work / 'scratch').write_bytes(b'held by appliance')
        self.assertTrue((work / 'scratch').exists())
        journal.write_text(json.dumps({'operation': 'prepare', 'computer': 'owner', 'phase': 'idle'}))
        with m._appliance_directory(self.root, 'completed-', guard) as completed:
            (completed / 'scratch').write_bytes(b'finished')
        self.assertFalse(completed.exists())

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
        def guestfish(args, env, log, timeout, size_limit, guard):
            calls.append((args, env))
            self.assertEqual(size_limit, m._READONLY_LIMIT)
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
        def guestfish(args, env, log, timeout, size_limit, guard):
            calls.append(args)
            self.assertEqual(size_limit, self.clone.stat().st_size + 1024 ** 3)
            return ''
        with patch.object(m, 'trusted_executable', side_effect=lambda p: Path(p)), patch.object(m, '_guestfish', guestfish):
            m.prepare_system_disk(self.clone, '6.12.0-test', hook, initrd, self.root)
        args = calls[0]
        self.assertNotIn('sh', [arg for i, arg in enumerate(args) if i == 0 or args[i - 1] != 'debug'])
        self.assertIn('rm-rf', args)
        self.assertIn('discard:enable', args)
        trim = args.index('fstrim')
        self.assertEqual(args[trim - 2:trim + 5], ['sync', ':', 'fstrim', '/', ':', 'sync', ':'])
        self.assertGreater(trim, args.index('rm-rf'))
        self.assertLess(trim, args.index('shutdown'))
        self.assertEqual(args[args.index('set-network') + 1], 'false')

    def test_hooks_use_only_independent_clone_and_fresh_readonly_download(self):
        hook_clone = self.root / 'hook.raw'
        hook_clone.write_bytes(b'guest copy')
        hook = self.root / 'hook'
        hook.write_bytes(b'hook')
        output = self.root / 'initrd'
        calls = []
        def guestfish(args, env, log, timeout, size_limit, guard):
            calls.append((args, env))
            self.assertEqual(size_limit, len(b'guest copy') + 1024 ** 3)
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
