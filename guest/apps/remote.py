"""Bounded, per-instance local transport for an agent app's remote bridge."""
import json
import hmac
import os
import socket
import struct
import threading

MAX_MESSAGE = 96 * 1024 * 1024
MAX_CLIENTS = 20


def read_exact(connection, count):
    data = bytearray()
    while len(data) < count:
        chunk = connection.recv(min(65536, count - len(data)))
        if not chunk:
            raise ConnectionError('bridge connection closed')
        data.extend(chunk)
    return bytes(data)


class GrantGate:
    """A display session's grant and its monotonically ordered documents."""

    def __init__(self):
        self.grant = None
        self.revision = -1
        self.document = None

    def update(self, grant):
        if grant == self.grant:
            return False
        self.grant = grant
        self.revision = -1
        self.document = None
        return True

    def matches(self, grant):
        return isinstance(grant, str) and isinstance(self.grant, str) and hmac.compare_digest(grant, self.grant)

    def opening(self, grant, document, revision):
        if not self.matches(grant):
            raise ValueError('This app is not handed off')
        if not isinstance(revision, int) or isinstance(revision, bool) or not 0 <= revision <= 2**53:
            raise ValueError('Invalid document revision')
        if revision < self.revision or (revision == self.revision and document != self.document):
            raise ValueError('This page has been replaced')
        return revision > self.revision

    def commit(self, document, revision):
        self.document = document
        self.revision = revision

    def close_document(self):
        self.document = None


class BridgeServer:
    """Serve one JSON request per connection on a random, private Unix socket."""

    def __init__(self, path, dispatch):
        self.path = path
        self.dispatch = dispatch
        self.lock = threading.Lock()
        self.clients = set()
        self.slots = threading.BoundedSemaphore(MAX_CLIENTS)
        self.large_slots = threading.BoundedSemaphore(2)
        self.closed = False
        self.listener = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        bound = False
        try:
            self.listener.bind(path)
            bound = True
            os.chmod(path, 0o600)
            self.listener.listen(MAX_CLIENTS)
            self.listener.settimeout(1)
        except BaseException:
            self.listener.close()
            if bound:
                try:
                    os.unlink(path)
                except FileNotFoundError:
                    pass
            raise
        self.thread = threading.Thread(target=self._accept, daemon=True)
        self.thread.start()

    def _accept(self):
        while not self.closed:
            try:
                connection, _ = self.listener.accept()
            except socket.timeout:
                continue
            except OSError:
                break
            if not self.slots.acquire(blocking=False):
                connection.close()
                continue
            with self.lock:
                if self.closed:
                    connection.close()
                    self.slots.release()
                    break
                self.clients.add(connection)
            threading.Thread(target=self._serve, args=(connection,), daemon=True).start()

    def _serve(self, connection):
        large = False
        try:
            connection.settimeout(660)
            size, = struct.unpack('<I', read_exact(connection, 4))
            if size > MAX_MESSAGE:
                return
            if size > 1024 * 1024:
                large = self.large_slots.acquire(blocking=False)
                if not large:
                    return
            request = json.loads(read_exact(connection, size))
            if not large and isinstance(request, dict) and request.get('method') in ('files.read', 'exec'):
                large = self.large_slots.acquire(blocking=False)
                if not large:
                    answer = b'{"ok":false,"error":"App bridge is busy"}'
                    connection.sendall(struct.pack('<I', len(answer)))
                    connection.sendall(answer)
                    return
            try:
                result = self.dispatch(request)
            except Exception:
                result = {'ok': False, 'error': 'Bridge request failed'}
            answer = json.dumps(result, separators=(',', ':')).encode()
            if len(answer) > MAX_MESSAGE:
                answer = b'{"ok":false,"error":"Bridge reply too large"}'
            connection.sendall(struct.pack('<I', len(answer)))
            connection.sendall(answer)
        except Exception:
            pass
        finally:
            with self.lock:
                self.clients.discard(connection)
            connection.close()
            if large:
                self.large_slots.release()
            self.slots.release()

    def close(self):
        with self.lock:
            if self.closed:
                return
            self.closed = True
            clients = list(self.clients)
        self.listener.close()
        for client in clients:
            try:
                client.shutdown(socket.SHUT_RDWR)
            except OSError:
                pass
        self.thread.join(2)
        try:
            os.unlink(self.path)
        except FileNotFoundError:
            pass
