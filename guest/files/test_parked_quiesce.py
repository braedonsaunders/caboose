import unittest
import errno
import tempfile
from pathlib import Path
from unittest.mock import patch
from parked_quiesce import Unsupported, branch_states, bridge_processes, cgroup_tree, check_control_plane, check_mounts, check_processes, freeze, freeze_branches, freeze_filesystem, plan_freezer_branches, recovery_ancestry, thaw, userspace_tree

ROOT = '1 0 8:1 / / rw - ext4 /dev/vda rw\n'

class QuiesceChecks(unittest.TestCase):
    def test_kernel_thread_flag_is_required_and_empty_userspace_cmdline_is_not_exempt(self):
        with tempfile.TemporaryDirectory() as directory:
            proc = Path(directory)
            for pid, status in ((1, 'Kthread:\t0\n'), (2, 'Kthread:\t1\n'), (42, 'Kthread:\t0\n')):
                (proc / str(pid)).mkdir()
                (proc / str(pid) / 'status').write_text(status)
                (proc / str(pid) / 'cmdline').write_bytes(b'')
            tree = userspace_tree({'/': [1, 2, 42]}, directory)
            self.assertEqual(tree, {'/': [1, 42]})
            with self.assertRaises(Unsupported): plan_freezer_branches(tree, [1])
            (proc / '42' / 'status').write_text('Name:\tworker\n')
            with self.assertRaises(Unsupported): userspace_tree({'/': [1, 42]}, directory)
            (proc / '42' / 'status').write_text('Kthread:\t1\nKthread:\t0\n')
            with self.assertRaises(Unsupported): userspace_tree({'/': [42]}, directory)
            (proc / '42' / 'status').unlink()
            with self.assertRaises(Unsupported): userspace_tree({'/': [42]}, directory)

    def test_recovery_ancestry_rejects_missing_init(self):
        with tempfile.TemporaryDirectory() as directory:
            proc = Path(directory)
            (proc / '10').mkdir()
            (proc / '10' / 'status').write_text('PPid:\t0\n')
            with self.assertRaises(Unsupported): recovery_ancestry(directory, 10)

    def test_ambiguous_filesystem_freeze_attempts_thaw(self):
        recorded = [{'path': '/user.slice', 'frozen': False}]
        with tempfile.TemporaryDirectory() as directory:
            proc = Path(directory)
            (proc / 'self').mkdir()
            (proc / 'self' / 'mountinfo').write_text(ROOT)
            with patch('parked_quiesce.os.stat') as stat, patch('parked_quiesce.cgroup_tree', return_value={}), patch('parked_quiesce.recovery_ancestry', return_value=[1]), patch('parked_quiesce.bridge_processes', return_value=[2]), patch('parked_quiesce.check_control_plane'), patch('parked_quiesce.freeze_branches'), patch('parked_quiesce.freeze_filesystem', side_effect=OSError('unknown outcome')), patch('parked_quiesce.thaw') as recover:
                stat.return_value.st_dev = 5
                with self.assertRaises(OSError): freeze({'branches': recorded, 'homeDevice': 5}, proc=directory)
            recover.assert_called_once_with(branches=recorded)

    def test_bridge_listener_and_children_are_protected_and_unknown_peer_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            proc = Path(directory)
            argv = b'/usr/bin/socat\0VSOCK-LISTEN:5252,fork,reuseaddr\0UNIX-CONNECT:/run/desk-guest-agent.sock\0'
            for pid, parent in ((20, 1), (21, 20)):
                base = proc / str(pid); base.mkdir()
                (base / 'exe').symlink_to('/usr/bin/socat1')
                (base / 'cmdline').write_bytes(argv)
                (base / 'status').write_text(f'PPid:\t{parent}\n')
            nodes = {'/': [1], '/system.slice': [], '/system.slice/desk-guest-agent.service': [10, 11], '/system.slice/desk-vsock-bridge.service': [20, 21], '/system.slice/writer.service': [30]}
            bridge = bridge_processes(nodes, directory)
            self.assertEqual(bridge, [20, 21])
            self.assertEqual(plan_freezer_branches(nodes, [1, 10, 11, *bridge]), ['/system.slice/writer.service'])
            (proc / '21' / 'cmdline').write_bytes(b'/bin/unknown\0')
            with self.assertRaises(Unsupported): bridge_processes(nodes, directory)
            (proc / '21' / 'cmdline').write_bytes(argv)
            (proc / '21' / 'exe').unlink()
            (proc / '21' / 'exe').symlink_to('/tmp/socat1')
            with self.assertRaises(Unsupported): bridge_processes(nodes, directory)

    def test_changed_bridge_after_freeze_rolls_back_via_thaw(self):
        recorded = [{'path': '/user.slice', 'frozen': False}]
        with tempfile.TemporaryDirectory() as directory:
            proc = Path(directory); (proc / 'self').mkdir()
            (proc / 'self' / 'mountinfo').write_text(ROOT)
            with patch('parked_quiesce.os.stat') as stat, patch('parked_quiesce.cgroup_tree', return_value={}), patch('parked_quiesce.recovery_ancestry', return_value=[1]), patch('parked_quiesce.bridge_processes', side_effect=[[2], [2, 3]]), patch('parked_quiesce.check_control_plane'), patch('parked_quiesce.freeze_branches'), patch('parked_quiesce.freeze_filesystem') as fsfreeze, patch('parked_quiesce.thaw') as recover:
                stat.return_value.st_dev = 5
                with self.assertRaises(Unsupported): freeze({'branches': recorded, 'homeDevice': 5}, proc=directory)
            fsfreeze.assert_not_called()
            recover.assert_called_once_with(branches=recorded)

    def test_changed_home_device_refuses_freeze(self):
        with tempfile.TemporaryDirectory() as directory:
            proc = Path(directory)
            (proc / 'self').mkdir()
            (proc / 'self' / 'mountinfo').write_text(ROOT)
            with patch('parked_quiesce.os.stat') as stat, patch('parked_quiesce.freeze_branches') as freezer:
                stat.return_value.st_dev = 6
                with self.assertRaises(Unsupported): freeze({'branches': [], 'homeDevice': 5}, proc=directory)
                freezer.assert_not_called()

    def test_control_plane_rejects_writable_shared_home_device_mapping(self):
        with tempfile.TemporaryDirectory() as directory:
            proc = Path(directory)
            for pid in (1, 10, 11):
                (proc / str(pid)).mkdir()
                (proc / str(pid) / 'status').write_text('Uid:\t0\t0\t0\t0\n')
                (proc / str(pid) / 'maps').write_text('1000-2000 rw-s 00000000 08:01 22 /home/caboose/a\n' if pid == 10 else '')
            (proc / '10' / 'cmdline').write_bytes(b'/usr/bin/node\0/opt/desk-agent/desk-guest-agent.mjs\0')
            (proc / '11' / 'cmdline').write_bytes(b'/usr/bin/python3\0/opt/caboose/files/parked_quiesce.py\0freeze\0')
            with patch('parked_quiesce.os.readlink', return_value='/usr/lib/systemd/systemd'), patch('parked_quiesce.os.stat') as stat:
                stat.return_value.st_dev = __import__('os').makedev(8, 1)
                with self.assertRaises(Unsupported): check_control_plane([1, 10, 11], directory, pid=11)

    def test_control_plane_rejects_unknown_ancestry(self):
        with self.assertRaises(Unsupported): check_control_plane([1, 10, 11, 12], pid=11)

    def test_filesystem_freeze_syncs_before_ioctl_and_closes_descriptor(self):
        steps = []
        with patch('parked_quiesce.os.open', return_value=33), patch('parked_quiesce.os.close', side_effect=lambda fd: steps.append('close')), patch('parked_quiesce.os.sync', side_effect=lambda: steps.append('sync')), patch('parked_quiesce.fcntl.ioctl', side_effect=lambda *args: steps.append('freeze')):
            freeze_filesystem()
        self.assertEqual(steps, ['sync', 'freeze', 'close'])

    def test_cgroup_tree_reads_direct_pids_and_fails_on_missing_metadata(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / 'cgroup.procs').write_text('1\n')
            child = root / 'system.slice'
            child.mkdir()
            (child / 'cgroup.procs').write_text('55\n')
            self.assertEqual(cgroup_tree(directory), {'/': [1], '/system.slice': [55]})
            (child / 'cgroup.procs').unlink()
            with self.assertRaises(Unsupported): cgroup_tree(directory)

    def test_freezer_plan_includes_writer_outside_user_slice(self):
        nodes = {'/': [1], '/system.slice': [], '/system.slice/recovery.service': [10],
                 '/system.slice/other.service': [55], '/user.slice': [42]}
        self.assertEqual(plan_freezer_branches(nodes, [1, 10]), ['/system.slice/other.service', '/user.slice'])

    def test_freezer_plan_rejects_unaccounted_process_on_recovery_path(self):
        nodes = {'/': [1, 99], '/system.slice': [], '/system.slice/recovery.service': [10]}
        with self.assertRaises(Unsupported): plan_freezer_branches(nodes, [1, 10])

    def test_freezer_plan_rejects_missing_nodes_and_duplicate_processes(self):
        for nodes in ({'/': [1], '/missing/child': [2]}, {'/': [1], '/a': [1]}):
            with self.assertRaises(Unsupported): plan_freezer_branches(nodes, [1])

    def test_changed_tree_rolls_back_attempted_freezes(self):
        nodes = {'/': [1], '/user.slice': [42], '/system.slice': [55]}
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            for name in ('user.slice', 'system.slice'):
                (root / name).mkdir()
                (root / name / 'cgroup.events').write_text('frozen 0\n')
            recorded = branch_states(nodes, [1], directory)
            with patch('parked_quiesce.cgroup_tree', return_value={'/': [1]}), patch('parked_quiesce.userspace_tree', side_effect=lambda tree, proc: tree), patch('parked_quiesce.set_frozen') as set_freeze:
                with self.assertRaises(Unsupported): freeze_branches(nodes, [1], recorded, directory)
                self.assertEqual([call.args[1] for call in set_freeze.call_args_list], [True, True, False, False])

    def test_owner_outside_slice_is_refused(self):
        with self.assertRaises(Unsupported):
            check_processes([(42, 1000, '/user.slice/user-1000.slice', '')])

    def test_mmap_writer_outside_user_slice_is_refused(self):
        maps = '1000-2000 rw-s 00000000 08:01 42 /home/caboose/document\n'
        with self.assertRaises(Unsupported):
            check_processes([(55, 0, '/system.slice/other.service', maps)])

    def test_managed_owner_is_accepted(self):
        check_processes([(42, 1000, '/caboose-workloads.slice/app.service', '')])

    def test_invalid_mapping_is_refused(self):
        with self.assertRaises(Unsupported):
            check_processes([(55, 0, '/system.slice/other.service', 'bad mapping')])

    def test_home_mount_is_refused(self):
        check_mounts(ROOT)
        check_mounts(ROOT + '2 1 0:42 / /home/caboose/.cache rw - tmpfs tmpfs rw,uid=1000,gid=1000\n')
        with self.assertRaises(Unsupported):
            check_mounts(ROOT + '2 1 0:42 / /home/caboose/media rw - tmpfs tmpfs rw\n')
        with self.assertRaises(Unsupported):
            check_mounts(ROOT + '2 1 0:42 / /home/caboose/.cache rw - ext4 /dev/vdb rw\n')
        with self.assertRaises(Unsupported):
            check_mounts(ROOT + '2 1 0:42 / /home/caboose/.cache rw - tmpfs tmpfs rw\n3 2 0:43 / /home/caboose/.cache/other rw - tmpfs tmpfs rw\n')
        with self.assertRaises(Unsupported):
            check_mounts(ROOT.replace('ext4', 'overlay'))

    @patch('parked_quiesce.set_frozen')
    @patch('parked_quiesce.fcntl.ioctl')
    def test_thaw_unfreezes_filesystem_before_slice(self, ioctl, freezer):
        with patch('parked_quiesce.os.open', return_value=33), patch('parked_quiesce.os.close'), patch('parked_quiesce.Path.exists', return_value=True):
            thaw()
        ioctl.assert_called_once()
        freezer.assert_called_once_with('/sys/fs/cgroup/caboose-workloads.slice', False)

    @patch('parked_quiesce.set_frozen')
    @patch('parked_quiesce.fcntl.ioctl', side_effect=OSError(errno.EIO, 'error'))
    def test_thaw_failure_does_not_release_slice(self, ioctl, freezer):
        with patch('parked_quiesce.os.open', return_value=33), patch('parked_quiesce.os.close'), patch('parked_quiesce.Path.exists', return_value=True):
            with self.assertRaises(OSError): thaw()
        freezer.assert_not_called()

    @patch('parked_quiesce.set_frozen')
    @patch('parked_quiesce.fcntl.ioctl', side_effect=OSError(errno.EINVAL, 'not frozen'))
    def test_thaw_accepts_already_thawed_filesystem(self, ioctl, freezer):
        with patch('parked_quiesce.os.open', return_value=33), patch('parked_quiesce.os.close'), patch('parked_quiesce.Path.exists', return_value=True):
            thaw()
        freezer.assert_called_once()

    @patch('parked_quiesce.set_frozen')
    @patch('parked_quiesce.fcntl.ioctl')
    def test_thaw_restores_only_branches_caboose_froze(self, ioctl, freezer):
        branches = [{'path': '/user.slice', 'frozen': False}, {'path': '/system.slice', 'frozen': True}]
        with patch('parked_quiesce.os.open', return_value=33), patch('parked_quiesce.os.close'), patch('parked_quiesce.Path.exists', return_value=True):
            thaw(branches=branches)
        freezer.assert_called_once_with(Path('/sys/fs/cgroup/user.slice'), False)

    @patch('parked_quiesce.fcntl.ioctl')
    def test_invalid_recovery_branch_does_not_touch_filesystem(self, ioctl):
        with self.assertRaises(Unsupported): thaw(branches=[{'path': '/../../etc', 'frozen': False}])
        ioctl.assert_not_called()

if __name__ == '__main__':
    unittest.main()
