import importlib.machinery
import importlib.util
import os
import tempfile
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent


def load(name):
    loader = importlib.machinery.SourceFileLoader(name.replace('-', '_'), str(HERE / name))
    spec = importlib.util.spec_from_loader(loader.name, loader)
    module = importlib.util.module_from_spec(spec)
    loader.exec_module(module)
    return module


broker = load('caboose-fuse-broker')
fusermount = load('caboose-fusermount')


class Broker(unittest.TestCase):
    def test_a_users_mount_is_nosuid_nodev_and_owned_by_the_user(self):
        flags, source, kind, data = broker.mount_data('rw,nosuid,nodev,fsname=portal,subtype=portal,default_permissions', 7, 0o40000, 1000, 1000)
        self.assertEqual(flags, broker.MS_NOSUID | broker.MS_NODEV)
        self.assertEqual((source, kind), ('portal', 'fuse.portal'))
        self.assertEqual(data, 'fd=7,rootmode=40000,user_id=1000,group_id=1000,default_permissions')

    def test_options_fusermount_would_not_give_a_user_are_refused(self):
        for options in ('allow_other', 'suid,allow_root', 'fsname=a,b=c', 'max_read=x'):
            with self.assertRaises(broker.Refused):
                broker.mount_data(options, 7, 0o40000, 1000, 1000)

    def test_mountpoints_are_the_callers_own_under_its_runtime_directory(self):
        uid = os.getuid()
        with self.assertRaises(broker.Refused):
            broker.checked_mountpoint('/tmp', uid)
        with self.assertRaises(broker.Refused):
            broker.checked_mountpoint('relative/path', uid)


class Fusermount(unittest.TestCase):
    def test_libfuses_calls_are_understood(self):
        self.assertEqual(fusermount.parse(['-o', 'rw,fsname=portal', '--', '/run/user/1000/doc']), ('rw,fsname=portal', '/run/user/1000/doc', False, False, False))
        self.assertEqual(fusermount.parse(['--unmount', '--quiet', '--lazy', '--', '/run/user/1000/doc']), ('', '/run/user/1000/doc', True, True, True))
        with self.assertRaises(SystemExit):
            fusermount.parse(['--auto-unmount', '-o', 'rw', '--', '/x'])


if __name__ == '__main__':
    unittest.main()
