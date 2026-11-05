"""The broker's handling of earlier sessions' capability logs at a session's start."""
import importlib.util
from importlib.machinery import SourceFileLoader
import os
from pathlib import Path
import sys
import tempfile
import time
import unittest

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent / 'broker'))
loader = SourceFileLoader('caboose_capability_history_broker', str(HERE / 'caboose-gpu-broker'))
spec = importlib.util.spec_from_loader(loader.name, loader)
broker = importlib.util.module_from_spec(spec)
loader.exec_module(broker)


class RetireCapabilitiesTest(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='caboose-capabilities-')
        self.seat = Path(self.temporary.name)
        self.capabilities = self.seat / 'capabilities'
        self.capabilities.mkdir(mode=0o700)

    def tearDown(self):
        self.temporary.cleanup()

    def log(self, name, directory=None):
        path = (directory or self.capabilities) / name
        path.write_bytes(b'CBCQ\x02\x00\x00\x00')
        os.chmod(path, 0o600)
        return path

    def test_formats_logs_become_history_and_instance_logs_end(self):
        self.log('formats-0000000000000001.bin')
        self.log('instance-0000000000000002.bin')
        self.log('other.bin')
        broker.retire_capabilities(self.seat)
        history = self.capabilities / 'history'
        self.assertEqual(sorted(p.name for p in history.iterdir()), ['formats-0000000000000001.bin'])
        self.assertEqual(sorted(p.name for p in self.capabilities.iterdir()), ['history', 'other.bin'])

    def test_history_keeps_the_newest(self):
        history = self.capabilities / 'history'
        history.mkdir(mode=0o700)
        for index in range(broker.HISTORY_LOGS + 2):
            path = self.log(f'formats-{index:016x}.bin', history)
            os.utime(path, ns=(time.time_ns(), (index + 1) * 1_000_000_000))
        broker.retire_capabilities(self.seat)
        kept = sorted(p.name for p in history.iterdir())
        self.assertEqual(kept, [f'formats-{index:016x}.bin' for index in range(2, broker.HISTORY_LOGS + 2)])


if __name__ == '__main__':
    unittest.main()
