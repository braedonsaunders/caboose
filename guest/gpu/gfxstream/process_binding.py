"""Linux-only process identities for a private GPU broker; no wire protocol.

The caller owns the connected Unix socket. Each identity owns its peer pidfd.
This module neither opens a listener nor authenticates a remote executor.
"""
import dataclasses
import os
from pathlib import Path
import select
import socket
import struct
import threading

# Linux asm-generic/socket.h: SO_PEERPIDFD returns a pidfd for the connected
# peer, avoiding pidfd_open(SO_PEERCRED.pid)'s PID-reuse race.
SO_PEERCRED = getattr(socket, "SO_PEERCRED", 17)
SO_PEERPIDFD = 77
MAX_ID = (1 << 64) - 1
MAX_PROCESSES = 16
MAX_STREAMS = 64


def process_start_ticks(stat_line):
    """Read field 22, allowing spaces and parentheses in field 2 (comm)."""
    end = stat_line.rfind(')')
    if end < 0 or end + 2 >= len(stat_line) or stat_line[end + 1] != ' ':
        raise ValueError('malformed process stat')
    fields = stat_line[end + 2:].split()
    if len(fields) < 20:
        raise ValueError('truncated process stat')
    value = int(fields[19])
    if value < 0:
        raise ValueError('invalid start time')
    return value


def pidfd_pid(fd):
    lines = Path(f'/proc/self/fdinfo/{fd}').read_text().splitlines()
    fields = [line.split(':', 1)[1].strip() for line in lines if line.startswith('Pid:')]
    if len(fields) != 1:
        raise ValueError('missing pidfd identity')
    pid = int(fields[0])
    if pid <= 0:
        raise ValueError('peer process already exited')
    return pid


def pidfd_alive(fd):
    poller = select.poll()
    poller.register(fd, select.POLLIN | select.POLLHUP | select.POLLERR)
    return not poller.poll(0)


@dataclasses.dataclass
class PeerIdentity:
    uid: int
    pid: int
    start_ticks: int
    pidfd: int

    @classmethod
    def from_socket(cls, stream, required_uid, *, allow_seqpacket=False):
        allowed = (socket.SOCK_STREAM, socket.SOCK_SEQPACKET) if allow_seqpacket else (socket.SOCK_STREAM,)
        if stream.family != socket.AF_UNIX or stream.getsockopt(socket.SOL_SOCKET, socket.SO_TYPE) not in allowed:
            raise ValueError('expected connected Unix socket')
        raw = stream.getsockopt(socket.SOL_SOCKET, SO_PEERCRED, struct.calcsize('3i'))
        if len(raw) != struct.calcsize('3i'):
            raise ValueError('invalid peer credentials')
        pid, uid, _gid = struct.unpack('3i', raw)
        if uid != required_uid or pid <= 0:
            raise PermissionError('unauthorized local peer')
        fd = stream.getsockopt(socket.SOL_SOCKET, SO_PEERPIDFD)
        try:
            os.set_inheritable(fd, False)
            if not pidfd_alive(fd) or pidfd_pid(fd) != pid:
                raise ValueError('peer pidfd identity mismatch')
            start = process_start_ticks(Path(f'/proc/{pid}/stat').read_text())
            if not pidfd_alive(fd) or pidfd_pid(fd) != pid:
                raise ValueError('peer exited during identity check')
            return cls(uid, pid, start, fd)
        except BaseException:
            os.close(fd)
            raise

    def alive(self):
        return self.pidfd >= 0 and pidfd_alive(self.pidfd)

    def close(self):
        if self.pidfd >= 0:
            fd, self.pidfd = self.pidfd, -1
            os.close(fd)

    def __enter__(self):
        return self

    def __exit__(self, *_):
        self.close()


class ProcessBindings:
    """One active generation, with monotonic stream IDs and pidfd ownership.

    Call finish only after the executor's actual generation has finished. This
    local object does not itself observe or assert remote native completion.
    """
    def __init__(self):
        self._lock = threading.Lock()
        self._generation = 0
        self._active = False
        self._next_stream = 0
        self._next_process = 0
        self._peers = {}
        self._streams = {}

    def begin(self):
        with self._lock:
            if self._active:
                raise RuntimeError('generation already active')
            if self._generation == MAX_ID:
                raise OverflowError('generation exhausted')
            self._generation += 1
            self._active = True
            self._next_stream = 0
            self._next_process = 0
            return self._generation

    def bind(self, generation, peer):
        """Transfer ownership of peer on success; caller retains it on failure."""
        with self._lock:
            if not self._active or generation != self._generation:
                raise RuntimeError('stale generation')
            if not peer.alive():
                raise RuntimeError('peer exited')
            if self._next_stream == MAX_ID or len(self._streams) >= MAX_STREAMS:
                raise OverflowError('stream capacity exhausted')
            key = (peer.uid, peer.pid, peer.start_ticks)
            previous = self._peers.get(key)
            if previous is not None:
                existing, process_id = previous
                if not existing.alive():
                    raise RuntimeError('bound process exited')
                peer.close()
            else:
                if self._next_process == MAX_ID or len(self._peers) >= MAX_PROCESSES:
                    raise OverflowError('process capacity exhausted')
                self._next_process += 1
                process_id = self._next_process
                self._peers[key] = (peer, process_id)
            self._next_stream += 1
            self._streams[self._next_stream] = key
            return process_id, self._next_stream

    def identity(self, generation, stream_id, *, require_alive=True):
        """Resolve a retained binding; require_alive=False is retirement-only.

        Callers must never use an exited binding to admit or forward new work.
        Generation and stream membership remain mandatory during EOF draining.
        """
        with self._lock:
            if not self._active or generation != self._generation:
                raise RuntimeError('stale generation')
            key = self._streams.get(stream_id)
            if key is None:
                raise KeyError('unknown stream')
            peer, process_id = self._peers[key]
            if require_alive and not peer.alive():
                raise RuntimeError('bound process exited')
            return process_id, key

    def find_process(self, generation, peer):
        """Resolve a separately accepted local socket to an existing process."""
        with self._lock:
            if not self._active or generation != self._generation:
                raise RuntimeError('stale generation')
            key = (peer.uid, peer.pid, peer.start_ticks)
            existing = self._peers.get(key)
            if existing is None or not peer.alive() or not existing[0].alive():
                raise PermissionError('local socket does not match a live process')
            return existing[1]

    def duplicate_process_identity(self, generation, process_id):
        """Duplicate the held pidfd for a compositor BIND; caller closes it."""
        with self._lock:
            if not self._active or generation != self._generation:
                raise RuntimeError('stale generation')
            for key, (peer, current) in self._peers.items():
                if current == process_id:
                    if not peer.alive(): raise RuntimeError('bound process exited')
                    fd = os.dup(peer.pidfd)
                    try:
                        os.set_inheritable(fd, False)
                        if not peer.alive(): raise RuntimeError('bound process exited')
                        return key, fd
                    except BaseException:
                        os.close(fd)
                        raise
            raise KeyError('unknown process')

    def unbind_stream(self, generation, stream_id):
        with self._lock:
            if not self._active or generation != self._generation:
                raise RuntimeError('stale generation')
            if self._streams.pop(stream_id, None) is None:
                raise KeyError('unknown stream')

    def retire_process(self, generation, process_id):
        # Caller invokes only after receiving the real process-retired receipt.
        with self._lock:
            if not self._active or generation != self._generation:
                raise RuntimeError('stale generation')
            for key, (peer, current) in self._peers.items():
                if current == process_id:
                    if key in self._streams.values():
                        raise RuntimeError('process has active streams')
                    peer.close()
                    del self._peers[key]
                    return
            raise KeyError('unknown process')

    def finish(self, generation):
        with self._lock:
            if not self._active or generation != self._generation:
                raise RuntimeError('stale generation')
            for peer, _process_id in self._peers.values():
                peer.close()
            self._peers.clear()
            self._streams.clear()
            self._active = False
