"""Bounded, cancellable byte transport; it does not interpret Vulkan completion."""

from dataclasses import dataclass
import selectors
import socket
import threading
import time


@dataclass(frozen=True)
class Result:
    reason: str
    forwarded: tuple[int, int]
    peak_pending: tuple[int, int]
    error: str | None = None


class DuplexRelay:
    """Own two connected stream sockets for one admitted connection generation.

    The caller authenticates and associates both endpoints before construction.
    run() closes both sockets on every exit, including errors. cancel() wakes a
    blocked run without closing/reusing its descriptors from another thread.
    There is no listener, session negotiation, GPU ACK, or recovery in this class.
    """

    def __init__(self, left: socket.socket, right: socket.socket, *,
                 capacity: int = 64 * 1024, timeout: float = 90.0):
        if left is right or left.fileno() == right.fileno():
            raise ValueError("distinct endpoints required")
        if not 1 <= capacity <= 16 * 1024 * 1024:
            raise ValueError("invalid per-direction capacity")
        if not 0 < timeout <= 3600:
            raise ValueError("finite timeout required")
        self._ends = (left, right)
        self._capacity = capacity
        self._timeout = timeout
        self._wake_read, self._wake_write = socket.socketpair()
        self._wake_write.setblocking(False)
        self._cancelled = threading.Event()
        self._lock = threading.Lock()
        self._started = False
        self._closed = False

    def cancel(self):
        """Idempotent cancellation; safe while run is draining or exiting."""
        self._cancelled.set()
        with self._lock:
            if self._closed:
                return
            try:
                self._wake_write.send(b"x")
            except (BlockingIOError, OSError):
                pass

    def run(self) -> Result:
        with self._lock:
            if self._started:
                raise RuntimeError("relay is single-use")
            self._started = True
        # pending[i] contains bytes read from endpoint i for endpoint 1-i.
        pending = [bytearray(), bytearray()]
        read_eof = [False, False]
        write_closed = [False, False]
        forwarded = [0, 0]
        peak = [0, 0]
        deadline = time.monotonic() + self._timeout
        reason, error = "eof", None
        selector = selectors.DefaultSelector()
        try:
            selector.register(self._wake_read, selectors.EVENT_READ, None)
            for endpoint in self._ends:
                endpoint.setblocking(False)
            while True:
                if self._cancelled.is_set():
                    reason = "cancelled"
                    break
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    reason = "timeout"
                    break
                for i, endpoint in enumerate(self._ends):
                    # Finish forwarding all pre-EOF bytes before half-closing.
                    if read_eof[1-i] and not pending[1-i] and not write_closed[i]:
                        endpoint.shutdown(socket.SHUT_WR)
                        write_closed[i] = True
                    events = 0
                    if not read_eof[i] and len(pending[i]) < self._capacity:
                        events |= selectors.EVENT_READ
                    if pending[1-i] and not write_closed[i]:
                        events |= selectors.EVENT_WRITE
                    try:
                        selector.get_key(endpoint)
                    except KeyError:
                        if events:
                            selector.register(endpoint, events, i)
                    else:
                        if events:
                            selector.modify(endpoint, events, i)
                        else:
                            selector.unregister(endpoint)
                if all(read_eof) and not any(pending):
                    break
                for key, events in selector.select(remaining):
                    if self._cancelled.is_set():
                        break
                    i = key.data
                    if i is None:
                        continue
                    endpoint = self._ends[i]
                    if events & selectors.EVENT_WRITE:
                        try:
                            count = endpoint.send(pending[1-i])
                        except BlockingIOError:
                            count = 0
                        if count:
                            del pending[1-i][:count]
                            forwarded[1-i] += count
                    if events & selectors.EVENT_READ:
                        try:
                            data = endpoint.recv(min(65536, self._capacity-len(pending[i])))
                        except BlockingIOError:
                            continue
                        if data:
                            pending[i].extend(data)
                            peak[i] = max(peak[i], len(pending[i]))
                        else:
                            read_eof[i] = True
        except OSError as exc:
            reason, error = "io_error", f"{type(exc).__name__}: errno={exc.errno}"
        finally:
            selector.close()
            with self._lock:
                self._closed = True
                for endpoint in (*self._ends, self._wake_read, self._wake_write):
                    endpoint.close()
        return Result(reason, tuple(forwarded), tuple(peak), error)
