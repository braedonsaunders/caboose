import unittest
import errno
from unittest.mock import patch
from parked_quiesce import Unsupported, check_mounts, check_processes, thaw

ROOT = '1 0 8:1 / / rw - ext4 /dev/vda rw\n'

class QuiesceChecks(unittest.TestCase):
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
        with self.assertRaises(Unsupported):
            check_mounts(ROOT + '2 1 0:42 / /home/caboose/media rw - tmpfs tmpfs rw\n')
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

if __name__ == '__main__':
    unittest.main()
