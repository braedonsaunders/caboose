import array
import socket
import sys
import unittest
from unittest import mock
import ipc_handoff
import control_protocol as protocol


class Peer:
    pid = 42
    start_ticks = 123
    def __enter__(self): return self
    def __exit__(self, *_): pass
    def alive(self): return True


class IpcHandoffTests(unittest.TestCase):
    def test_non_tcp_fd_is_rejected(self):
        sender, receiver = socket.socketpair()
        endpoint, other = socket.socketpair()
        try:
            sender.sendmsg([b'G'], [(socket.SOL_SOCKET, socket.SCM_RIGHTS,
                                      array.array('i', [endpoint.fileno()]))])
            with mock.patch.object(ipc_handoff.PeerIdentity, 'from_socket', return_value=Peer()):
                with self.assertRaisesRegex(ValueError, 'not a TCP'):
                    ipc_handoff.receive_socket(receiver, 1000, 42, 123)
        finally:
            sender.close(); receiver.close(); endpoint.close(); other.close()

    @unittest.skipUnless(sys.platform == 'linux', 'Linux AF_UNIX SOCK_SEQPACKET')
    def test_seqpacket_response_preserves_record_boundary(self):
        sender, receiver = socket.socketpair(type=socket.SOCK_SEQPACKET)
        value = protocol.BindResult(7, 0, b'a' * 16, b'b' * 16, 12, 3)
        try:
            sender.send(protocol.encode_result(value))
            with mock.patch.object(ipc_handoff.PeerIdentity, 'from_socket', return_value=Peer()):
                self.assertEqual(ipc_handoff.receive_record(receiver, 1000, 42, 123), value)
        finally:
            sender.close(); receiver.close()

    @unittest.skipUnless(sys.platform == 'linux', 'Linux AF_UNIX SOCK_SEQPACKET')
    def test_truncated_seqpacket_is_rejected(self):
        sender, receiver = socket.socketpair(type=socket.SOCK_SEQPACKET)
        try:
            sender.send(b'CGB1' + bytes(100))
            with mock.patch.object(ipc_handoff.PeerIdentity, 'from_socket', return_value=Peer()):
                with self.assertRaises(ValueError):
                    ipc_handoff.receive_record(receiver, 1000, 42, 123)
        finally:
            sender.close(); receiver.close()

    def test_wrong_compositor_is_rejected_before_receiving(self):
        with mock.patch.object(ipc_handoff.PeerIdentity, 'from_socket', return_value=Peer()):
            with self.assertRaises(PermissionError):
                ipc_handoff.receive_socket(mock.Mock(), 1000, 41, 123)


if __name__ == '__main__': unittest.main()
