"""Receive one TCP socket from an authenticated compositor over private AF_UNIX.

The caller supplies an already accepted Unix stream, expected compositor uid and
expected pid/start-time tuple. This function owns neither the IPC stream nor the
compositor identity supplied by the caller; it returns an owned TCP socket.
"""
import array
import os
import socket

from process_binding import PeerIdentity


def receive_socket(ipc, required_uid, expected_pid, expected_start_ticks):
    with PeerIdentity.from_socket(ipc, required_uid, allow_seqpacket=True) as peer:
        if (peer.pid, peer.start_ticks) != (expected_pid, expected_start_ticks):
            raise PermissionError('unexpected compositor process')
        itemsize = array.array('i').itemsize
        data, controls, flags, _ = ipc.recvmsg(1, socket.CMSG_SPACE(itemsize * 2))
        descriptors = []
        try:
            unexpected = False
            for level, kind, contents in controls:
                if level == socket.SOL_SOCKET and kind == socket.SCM_RIGHTS:
                    if len(contents) % itemsize:
                        unexpected = True
                    received = array.array('i')
                    received.frombytes(contents[:len(contents) - len(contents) % itemsize])
                    descriptors.extend(received)
                else:
                    unexpected = True
            if unexpected or data != b'G' or flags & (socket.MSG_CTRUNC | socket.MSG_TRUNC) or len(descriptors) != 1:
                raise ValueError('invalid IPC socket transfer')
            fd = descriptors.pop()
            try:
                os.set_inheritable(fd, False)
                stream = socket.socket(fileno=fd)
            except BaseException:
                os.close(fd)
                raise
            try:
                if stream.family not in (socket.AF_INET, socket.AF_INET6) or stream.getsockopt(socket.SOL_SOCKET, socket.SO_TYPE) != socket.SOCK_STREAM:
                    raise ValueError('handoff is not a TCP stream')
                stream.getpeername()
                if not peer.alive():
                    raise ValueError('compositor exited during transfer')
                return stream
            except BaseException:
                stream.close()
                raise
        finally:
            for fd in descriptors:
                os.close(fd)
