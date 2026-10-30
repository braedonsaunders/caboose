import array
import socket
import unittest
from unittest import mock
import ipc_handoff


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

    def test_wrong_compositor_is_rejected_before_receiving(self):
        with mock.patch.object(ipc_handoff.PeerIdentity, 'from_socket', return_value=Peer()):
            with self.assertRaises(PermissionError):
                ipc_handoff.receive_socket(mock.Mock(), 1000, 41, 123)


if __name__ == '__main__': unittest.main()
