"""Authenticated CGB1/SCM_RIGHTS records on the compositor's private socket."""
import array
import os
import socket

import control_protocol
from process_binding import PeerIdentity


def receive_record(ipc, required_uid, expected_pid, expected_start_ticks):
    """Return a validated TCP socket or a typed control record; caller owns it."""
    with PeerIdentity.from_socket(ipc, required_uid, allow_seqpacket=True) as peer:
        if (peer.pid, peer.start_ticks) != (expected_pid, expected_start_ticks):
            raise PermissionError('unexpected compositor process')
        itemsize = array.array('i').itemsize
        data, controls, flags, _ = ipc.recvmsg(80, socket.CMSG_SPACE(itemsize * 2))
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
            if unexpected or flags & (socket.MSG_CTRUNC | socket.MSG_TRUNC):
                raise ValueError('truncated or unexpected IPC control')
            record = control_protocol.decode(data, len(descriptors))
            if not peer.alive():
                raise ValueError('compositor exited during transfer')
            if record != 'handoff':
                if not isinstance(record, (control_protocol.BindResult, control_protocol.RevokeGrant)):
                    raise ValueError('invalid compositor record direction')
                return record
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
                return stream
            except BaseException:
                stream.close()
                raise
        finally:
            for fd in descriptors:
                os.close(fd)


def receive_socket(ipc, required_uid, expected_pid, expected_start_ticks):
    record = receive_record(ipc, required_uid, expected_pid, expected_start_ticks)
    if not isinstance(record, socket.socket):
        raise ValueError('expected TCP handoff')
    return record
