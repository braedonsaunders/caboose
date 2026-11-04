"""Private GPU executor admission and bounded queued bytes.

Actual native ready/retired receipts are supplied by the broker; this module
never equates a transport disconnect with native generation completion.
"""
from collections import deque
from threading import Lock

# The broker's queue toward the phone holds as many bytes as its resume window (8 MiB), in
# at most MAX_QUEUED_FRAMES frames: room for that many bytes of 64 KiB DATA reads and their
# controls. Other bounded queues take at most MAX_QUEUED_MESSAGES messages.
MAX_QUEUED_BYTES = 8 * 1024 * 1024
MAX_QUEUED_FRAMES = 256
MAX_QUEUED_MESSAGES = 64


class BoundedQueue:
    def __init__(self):
        self._items = deque()
        self._bytes = 0
        self._lock = Lock()

    def put(self, message):
        if not isinstance(message, bytes):
            raise TypeError('queue requires immutable bytes')
        with self._lock:
            if len(self._items) >= MAX_QUEUED_MESSAGES or len(message) > MAX_QUEUED_BYTES - self._bytes:
                raise BufferError('GPU direction queue limit')
            self._items.append(message)
            self._bytes += len(message)

    def pop(self):
        with self._lock:
            if not self._items:
                return None
            value = self._items.popleft()
            self._bytes -= len(value)
            return value


class ExecutorLease:
    def __init__(self):
        self._lock = Lock()
        self._generation = 0
        self._state = 'idle'
        self._identity = None

    def admit(self, executor):
        with self._lock:
            if self._state != 'idle':
                raise RuntimeError('previous executor has not finished')
            if self._generation == (1 << 64) - 1:
                raise OverflowError('executor generation exhausted')
            if not executor or len(executor) != 16 or executor == bytes(16):
                raise ValueError('invalid executor identity')
            self._generation += 1
            self._identity = bytes(executor)
            self._state = 'pending'
            return self._generation

    def ready(self, executor, generation):
        with self._lock:
            self._check(executor, generation)
            if self._state != 'pending': raise RuntimeError('not pending')
            self._state = 'active'

    def revoke(self, executor, generation):
        with self._lock:
            self._check(executor, generation)
            if self._state not in ('pending', 'active', 'draining'):
                raise RuntimeError('not revocable')
            self._state = 'draining'

    def finished(self, executor, generation):
        """Caller invokes only after actual native generation finish receipt."""
        with self._lock:
            self._check(executor, generation)
            if self._state != 'draining': raise RuntimeError('generation not draining')
            self._identity = None
            self._state = 'idle'

    def held(self, executor, generation):
        """Whether this generation of the executor still holds the lease."""
        with self._lock:
            return self._identity == executor and self._generation == generation and self._state != 'idle'

    def abandoned(self, executor, generation):
        """The executor's connection was lost and the broker has ended every local client of
        the generation: nothing of it remains to finish, so a reconnect may be admitted."""
        with self._lock:
            if self._identity != executor or self._generation != generation or self._state == 'idle':
                return False
            self._identity = None
            self._state = 'idle'
            return True

    @property
    def idle(self):
        with self._lock: return self._state == 'idle'

    def _check(self, executor, generation):
        if self._identity != executor or self._generation != generation or self._state == 'idle':
            raise RuntimeError('stale executor generation')
