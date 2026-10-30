import socket
import struct
import unittest
from unittest import mock
import process_binding as binding


class FakePeer:
    def __init__(self, pid, start, uid=1000):
        self.pid, self.start_ticks, self.uid = pid, start, uid
        self.open = True
    def alive(self): return self.open
    def close(self): self.open = False


class FakeSocket:
    family = socket.AF_UNIX
    def __init__(self, uid=1000): self.uid = uid
    def getsockopt(self, _level, option, *args):
        if option == socket.SO_TYPE: return socket.SOCK_STREAM
        if option == binding.SO_PEERCRED: return struct.pack('3i', 42, self.uid, 1000)
        if option == binding.SO_PEERPIDFD: return 17
        raise AssertionError(option)


class ProcessBindingsTests(unittest.TestCase):
    def test_proc_stat_handles_spaces_and_right_parentheses(self):
        stat = '42 (a ) tricky) S ' + ' '.join(['1'] * 18 + ['9123'] + ['0'])
        self.assertEqual(binding.process_start_ticks(stat), 9123)
        for raw in ('', '3 (broken', '3 (name) S 1'):
            with self.assertRaises(ValueError): binding.process_start_ticks(raw)

    def test_authenticated_peer_uses_kernel_peer_pidfd(self):
        stat = '42 (game) S ' + ' '.join(['1'] * 18 + ['9123'])
        with mock.patch.object(binding.os, 'set_inheritable') as cloexec, \
             mock.patch.object(binding, 'pidfd_alive', return_value=True), \
             mock.patch.object(binding, 'pidfd_pid', return_value=42), \
             mock.patch.object(binding.Path, 'read_text', return_value=stat), \
             mock.patch.object(binding.os, 'close') as close:
            peer = binding.PeerIdentity.from_socket(FakeSocket(), 1000)
            self.assertEqual((peer.pid, peer.uid, peer.start_ticks), (42, 1000, 9123))
            cloexec.assert_called_once_with(17, False)
            peer.close(); peer.close(); close.assert_called_once_with(17)

    def test_bad_uid_and_mismatched_pid_fail_closed(self):
        with self.assertRaises(PermissionError): binding.PeerIdentity.from_socket(FakeSocket(1001), 1000)
        with mock.patch.object(binding.os, 'set_inheritable'), \
             mock.patch.object(binding, 'pidfd_alive', return_value=True), \
             mock.patch.object(binding, 'pidfd_pid', return_value=43), \
             mock.patch.object(binding.os, 'close') as close:
            with self.assertRaises(ValueError): binding.PeerIdentity.from_socket(FakeSocket(), 1000)
            close.assert_called_once_with(17)

    def test_generation_fences_streams_and_pid_reuse(self):
        registry = binding.ProcessBindings(); gen = registry.begin()
        with self.assertRaises(RuntimeError): registry.begin()
        first = FakePeer(42, 111); proc, stream = registry.bind(gen, first)
        second = FakePeer(42, 111); proc2, stream2 = registry.bind(gen, second)
        self.assertFalse(second.open)
        self.assertEqual(proc2, proc)
        self.assertEqual(registry.identity(gen, stream2), (proc, (1000, 42, 111)))
        reused = FakePeer(42, 222); proc3, stream3 = registry.bind(gen, reused)
        self.assertNotEqual(proc3, proc)
        self.assertEqual(registry.identity(gen, stream3), (proc3, (1000, 42, 222)))
        first.close()
        with self.assertRaises(RuntimeError): registry.identity(gen, stream)
        registry.finish(gen); self.assertFalse(reused.open)
        newgen = registry.begin(); self.assertNotEqual(newgen, gen)
        with self.assertRaises(RuntimeError): registry.identity(gen, stream)
        with self.assertRaises(RuntimeError): registry.finish(gen)
        registry.finish(newgen)

    def test_retirement_and_limits(self):
        registry = binding.ProcessBindings(); gen = registry.begin()
        peer = FakePeer(10, 1); process, first = registry.bind(gen, peer)
        with self.assertRaises(RuntimeError): registry.retire_process(gen, process)
        registry.unbind_stream(gen, first)
        registry.retire_process(gen, process)
        self.assertFalse(peer.open)
        new_process, new_stream = registry.bind(gen, FakePeer(10, 1))
        self.assertGreater(new_process, process)
        self.assertGreater(new_stream, first)
        for pid in range(20, 35): registry.bind(gen, FakePeer(pid, 1))
        extra = FakePeer(100, 1)
        with self.assertRaises(OverflowError): registry.bind(gen, extra)
        self.assertTrue(extra.open)
        registry.finish(gen)

    def test_stream_capacity_releases_without_reusing_id(self):
        registry = binding.ProcessBindings(); gen = registry.begin()
        for _ in range(binding.MAX_STREAMS): process, stream = registry.bind(gen, FakePeer(1, 1))
        extra = FakePeer(1, 1)
        with self.assertRaises(OverflowError): registry.bind(gen, extra)
        self.assertTrue(extra.open)
        registry.unbind_stream(gen, stream)
        process2, stream2 = registry.bind(gen, extra)
        self.assertEqual(process2, process)
        self.assertGreater(stream2, stream)
        registry.finish(gen)

    def test_exhaustion_does_not_take_peer(self):
        registry = binding.ProcessBindings(); gen = registry.begin()
        registry._next_stream = binding.MAX_ID
        peer = FakePeer(1, 1)
        with self.assertRaises(OverflowError): registry.bind(gen, peer)
        self.assertTrue(peer.open)
        registry.finish(gen)


if __name__ == '__main__': unittest.main()
