"""Private event snapshots. Disk queues remain authoritative until consumer ACK.

One bounded long poll owns one inotify descriptor; it has no worker thread. Watches
cover only fixed queue/state directories and the explicitly selected task scopes.
"""
import base64
import ctypes
import hashlib
import hmac
import itertools
import json
import os
import re
import secrets
import select
import stat
import struct
import threading
import time

UUID = re.compile(r'[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}\Z')
HEX = re.compile(r'[0-9a-f]{32}\Z')
CHANNELS = frozenset(('bridge.request', 'bridge.cancel', 'phone', 'notification', 'now-playing', 'media', 'agent.tick', 'agent.mailbox', 'fs'))
QUEUES = {'bridge.request': ('.cache/caboose/bridge/claimed', 65536),
          'bridge.cancel': ('.cache/caboose/bridge/cancels', 1),
          'phone': ('.cache/caboose/phone/queue', 16384),
          'notification': ('.cache/caboose/notifications', 32768)}
MAX_OUTPUT = 1024 * 1024
MAX_RECORDS = 128


def encode(value):
    return json.dumps(value, separators=(',', ':'), ensure_ascii=True).encode()


def request(value):
    if not isinstance(value, dict): raise ValueError('request')
    channels = value.get('channels')
    if not isinstance(channels, list) or len(channels) > len(CHANNELS) or any(not isinstance(c, str) or c not in CHANNELS for c in channels): raise ValueError('channels')
    tasks = value.get('tasks', [])
    if not isinstance(tasks, list) or len(tasks) > 256: raise ValueError('tasks')
    seen = set()
    for task in tasks:
        if not isinstance(task, dict) or not isinstance(task.get('id'), str) or not UUID.fullmatch(task['id']) or task['id'] in seen: raise ValueError('task')
        seen.add(task['id'])
        for key in ('offset', 'turn'):
            n = task.get(key, 0)
            if type(n) is not int or not 0 <= n <= 2**53 - 1: raise ValueError(key)
    if type(value.get('phone')) is not bool: raise ValueError('phone')
    if not isinstance(value.get('session'), str) or not HEX.fullmatch(value['session']): raise ValueError('session')
    if type(value.get('generation')) is not int or not 0 <= value['generation'] <= 2**53 - 1: raise ValueError('generation')
    if not isinstance(value.get('cursor', ''), str) or len(value.get('cursor', '')) > 128: raise ValueError('cursor')
    acks = value.get('acks', [])
    if not isinstance(acks, list) or len(acks) > MAX_RECORDS or any(not isinstance(a, str) or len(a) > 1024 for a in acks): raise ValueError('acks')
    return value


def process_running(pid):
    if not pid.isdigit() or not 0 < int(pid) < 2**31: return False
    try:
        with open('/proc/%d/stat' % int(pid), 'rb') as f:
            # comm can contain spaces and parentheses; state follows the final ')'.
            state = f.read(65536).rsplit(b')', 1)[1].split()[0]
        return state not in (b'Z', b'X')
    except (OSError, IndexError): return False


class Store:
    def __init__(self, directory):
        self.directory = directory
        self.secret = secrets.token_bytes(32)
        self.accepted_bridge = set()
        self.pages = {}
        self.visited = set()
        self.transcripts = {}
        self.task_page = 0
        self.task_scope = ()

    def read(self, path, limit, offset=None, tail=False):
        d, name = path.rsplit('/', 1)
        fd = self.directory(d.split('/'))
        try: f = os.open(name, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK | os.O_CLOEXEC, dir_fd=fd)
        finally: os.close(fd)
        try:
            s = os.fstat(f)
            if not stat.S_ISREG(s.st_mode): raise ValueError('regular file required')
            os.lseek(f, max(0, s.st_size-limit) if tail else (offset or 0), os.SEEK_SET)
            data = os.read(f, limit if tail or offset is not None else limit + 1)
            if len(data) > limit: raise ValueError('record too large')
            return data, s
        finally: os.close(f)

    def optional(self, path, limit, **kw):
        try: return self.read(path, limit, **kw)[0]
        except (OSError, ValueError): return b''

    def names(self, path, limit=256):
        self.visited.add(path)
        try: fd = self.directory(path.split('/'))
        except OSError: return []
        try:
            with os.scandir(fd) as entries:
                offset = self.pages.get(path, 0)
                batch = [entry.name for entry in itertools.islice(entries, offset, offset + limit)]
                self.pages[path] = offset + limit if len(batch) == limit else 0
                return batch
        finally: os.close(fd)

    def receipt(self, channel, name, data, s):
        payload = encode([channel, name, s.st_dev, s.st_ino, s.st_mtime_ns, hashlib.sha256(data).hexdigest()])
        return base64.urlsafe_b64encode(payload).decode() + '.' + hmac.new(self.secret, payload, hashlib.sha256).hexdigest()

    def ack(self, token):
        try:
            body, signature = token.split('.')
            payload = base64.b64decode(body, altchars=b'-_', validate=True)
            if not hmac.compare_digest(signature, hmac.new(self.secret, payload, hashlib.sha256).hexdigest()): return
            channel, name, *_ = json.loads(payload)
            if channel not in QUEUES or '/' in name or name in ('.', '..'): raise ValueError('receipt')
            if channel == 'bridge.request':
                if len(self.accepted_bridge) >= 4096: self.accepted_bridge.clear()
                self.accepted_bridge.add(token)
                return  # The response helper retires claimed requests.
            path, limit = QUEUES[channel]
            data, s = self.read(path + '/' + name, limit)
            if not hmac.compare_digest(token, self.receipt(channel, name, data, s)): return
            fd = self.directory(path.split('/'))
            try:
                # Queue producers publish unique names atomically. Recheck identity under
                # this directory immediately before removing the accepted version.
                now = os.stat(name, dir_fd=fd, follow_symlinks=False)
                if (now.st_ino, now.st_mtime_ns, now.st_size) == (s.st_ino, s.st_mtime_ns, s.st_size): os.unlink(name, dir_fd=fd)
            finally: os.close(fd)
        except (FileNotFoundError, ValueError): pass  # ACK replay/old service receipt is a no-op.

    def claim_bridge(self):
        path = '.cache/caboose/bridge'
        try: parent = self.directory(path.split('/'))
        except OSError: return
        try:
            try: os.mkdir('claimed', 0o700, dir_fd=parent)
            except FileExistsError: pass
        finally: os.close(parent)
        try:
            src = self.directory((path + '/requests').split('/'))
            try: dst = self.directory((path + '/claimed').split('/'))
            except BaseException: os.close(src); raise
        except OSError: return
        try:
            for name in self.names(path + '/requests'):
                if not name.endswith('.json') or not HEX.fullmatch(name[:-5]): continue
                # Validate complete JSON before claiming; a partial writer stays pending.
                try:
                    data, _ = self.read(path + '/requests/' + name, 65536)
                    json.loads(data)
                    # Unique bridge IDs; never replace an existing pending request.
                    os.link(name, name, src_dir_fd=src, dst_dir_fd=dst, follow_symlinks=False)
                    os.unlink(name, dir_fd=src)
                except (OSError, ValueError): continue
        finally: os.close(src); os.close(dst)

    def snapshot(self, value, fs_anchor):
        records = []; size = 256; more = False
        self.visited = set()
        def emit(channel, record, receipt=None):
            nonlocal size, more
            row = {'channel': channel, 'record': record}
            if receipt: row['receipt'] = receipt
            length = len(encode(row))
            if len(records) >= MAX_RECORDS or size + length > MAX_OUTPUT - 1024:
                more = True; return False
            records.append(row); size += length
            return True
        channels = set(value['channels'])
        if 'bridge.request' in channels: self.claim_bridge()
        for channel in channels & QUEUES.keys():
            path, limit = QUEUES[channel]
            for name in self.names(path):
                if channel == 'bridge.cancel':
                    if not HEX.fullmatch(name): continue
                elif not name.endswith('.json'): continue
                try:
                    data, s = self.read(path + '/' + name, limit)
                    record = name if channel == 'bridge.cancel' else json.loads(data)
                    receipt = self.receipt(channel, name, data, s)
                    if receipt in self.accepted_bridge: continue
                    if not emit(channel, record, receipt): break
                except (OSError, ValueError): continue
        for channel in channels & {'now-playing', 'media'}:
            try:
                pidpath, process = ('bridge/daemon.pid', b'caboose-bridge') if channel == 'now-playing' else ('media-host.pid', b'caboose-media-host')
                pid = self.optional('.cache/caboose/' + pidpath, 32).strip()
                alive = False
                if pid.isdigit() and 0 < int(pid) < 2**31:
                    try:
                        with open('/proc/%d/cmdline' % int(pid), 'rb') as f: alive = process in f.read(65536)
                    except OSError: pass
                state = json.loads(self.optional('.cache/caboose/' + channel + '.json', 65536)) if alive else None
            except ValueError: state = None
            emit(channel, {'state': state, 'guestClockMs': int(time.time()*1000)})
        budget = min(65536, 262144 // max(1, len(value.get('tasks', []))))
        tasks = value.get('tasks', [])
        task_scope = tuple(task['id'] for task in tasks)
        if task_scope != self.task_scope: self.task_page = 0
        self.task_scope = task_scope
        task_start = min(self.task_page, max(0, len(tasks)-1))
        self.task_page = 0
        for task_index in range(task_start, len(tasks)):
            task = tasks[task_index]
            if len(records) >= MAX_RECORDS - 2 or size >= MAX_OUTPUT - 500000:
                self.task_page = task_index; more = True; break
            base = 'Agents/' + task['id']; offset = task.get('offset', 0)
            if 'agent.tick' in channels:
                try:
                    data, s = self.read(base + '/transcript.jsonl', budget, offset=offset)
                    previous = self.transcripts.get(task['id'])
                    reset = offset > s.st_size or bool(previous and previous[0] != (s.st_dev, s.st_ino))
                    boundary = previous[1].get(offset) if previous else None
                    if boundary:
                        continuity, _ = self.read(base + '/transcript.jsonl', len(boundary), offset=max(0, offset-len(boundary)))
                        reset = reset or continuity != boundary
                    if reset: data, s = self.read(base + '/transcript.jsonl', budget, offset=0)
                except (OSError, ValueError): data = b''; reset = False
                start = 0 if reset else offset
                if data:
                    boundaries = {} if reset or not previous else {offset: previous[1][offset]} if offset in previous[1] else {}
                    boundaries[start+len(data)] = data[-64:]
                    self.transcripts[task['id']] = ((s.st_dev, s.st_ino), boundaries)
                exitcode = self.optional(base + '/exit-code', 64).decode(errors='replace').strip()
                if not exitcode:
                    pid = self.optional(base + '/pid', 32).strip()
                    try:
                        if not process_running(pid): raise ProcessLookupError()
                    except OSError: exitcode = 'interrupted'
                stderr = self.optional(base + '/stderr.log', 400, tail=True)
                b64 = lambda x: base64.b64encode(x).decode()
                output = 'T\t%s\t%s\t%s\t%s\n' % (task['id'], exitcode, b64(stderr), b64(data))
                output += 'D\t%s\t%s\n' % (task['id'], b64(self.optional(base + '/draft.json', 131072)))
                for name in self.names(base + '/approvals', limit=2):
                    if not name.endswith('.json') or not UUID.fullmatch(name[:-5]): continue
                    if self.optional(base + '/approvals/' + name[:-5] + '.decision', 65536): continue
                    approval = self.optional(base + '/approvals/' + name, 65536)
                    if len(output) + len(approval)*2 > 262144: more = True; break
                    output += 'A\t%s\t%s\t%s\n' % (task['id'], name[:-5], b64(approval))
                emit('agent.tick', {'id': task['id'], 'offset': start, 'nextOffset': start+len(data), 'reset': reset, 'output': output, 'chunk': budget})
                if len(data) == budget: more = True
            if 'agent.mailbox' in channels:
                for name in self.names(base + '/tool-mailbox'):
                    if not name.endswith('.request') or not UUID.fullmatch(name[:-8]): continue
                    try:
                        response, rs = self.read(base + '/tool-mailbox/' + name[:-8] + '.response', 1048576)
                        data, qs = self.read(base + '/tool-mailbox/' + name, 65536)
                        if time.time() - max(rs.st_mtime, qs.st_mtime) > 120:
                            d = self.directory((base + '/tool-mailbox').split('/'))
                            try:
                                os.unlink(name, dir_fd=d)
                                os.unlink(name[:-8] + '.response', dir_fd=d)
                            finally: os.close(d)
                        continue
                    except (OSError, ValueError): pass
                    data = self.optional(base + '/tool-mailbox/' + name, 65536)
                    try:
                        payload = json.loads(data)
                        valid = isinstance(payload, dict) and set(payload) == {'id', 'turn', 'tool', 'arguments'} and payload['id'] == name[:-8] and type(payload['turn']) is int and payload['turn'] == task.get('turn') and isinstance(payload['tool'], str) and isinstance(payload['arguments'], dict)
                    except ValueError: valid = False
                    if valid and not emit('agent.mailbox', {'id': task['id'], 'request': base64.b64encode(data).decode()}): break
        if 'fs' in channels: emit('fs', {'anchor': fs_anchor})
        self.transcripts = {k: v for k, v in self.transcripts.items() if k in {t['id'] for t in value.get('tasks', [])}}
        self.pages = {p: n for p, n in self.pages.items() if p in self.visited}
        return records, more or any(self.pages.values())


class Watch:
    """Fixed ancestors allow late creation; selected tasks retire when poll closes."""
    def __init__(self, directory, tasks):
        self.directory = directory
        self.libc = ctypes.CDLL(None, use_errno=True)
        self.processes = []
        self.fd = self.libc.inotify_init1(os.O_NONBLOCK | os.O_CLOEXEC)
        if self.fd < 0: raise OSError(ctypes.get_errno(), 'inotify_init1')
        paths = {'', '.cache', '.cache/caboose', '.cache/caboose/notifications', '.cache/caboose/phone', '.cache/caboose/phone/queue', '.cache/caboose/bridge', '.cache/caboose/bridge/requests', '.cache/caboose/bridge/claimed', '.cache/caboose/bridge/cancels', 'Agents'}
        for task in tasks:
            base = 'Agents/' + task['id']
            paths.update((base, base + '/approvals', base + '/tool-mailbox'))
        try:
            for path in paths:
                try: d = directory(path.split('/') if path else [])
                except FileNotFoundError: continue
                try:
                    # close-write, moved-to/from, create/delete, self-delete/move;
                    # no IN_OPEN/ACCESS, avoiding feedback from our reads.
                    if self.libc.inotify_add_watch(self.fd, os.fsencode('/proc/self/fd/%d' % d), 0xFCA | 0x01000000) < 0:
                        raise OSError(ctypes.get_errno(), 'inotify_add_watch')
                finally: os.close(d)
            if hasattr(os, 'pidfd_open'):
                store = Store(directory)
                pidpaths = ['Agents/' + t['id'] + '/pid' for t in tasks]
                pidpaths += ['.cache/caboose/bridge/daemon.pid', '.cache/caboose/media-host.pid']
                for path in pidpaths:
                    pid = store.optional(path, 32).strip()
                    if process_running(pid):
                        try: self.processes.append(os.pidfd_open(int(pid)))
                        except OSError: pass
        except BaseException: self.close(); raise

    @staticmethod
    def changed(data):
        pos = 0
        while pos + 16 <= len(data):
            wd, mask, cookie, length = struct.unpack_from('iIII', data, pos)
            name = data[pos+16:pos+16+length].split(b'\0', 1)[0]
            pos += 16 + length
            if name != b'present': return True  # Includes overflow and self/rename events.
        return False

    def close(self):
        for fd in self.processes: os.close(fd)
        os.close(self.fd)


class Events:
    def __init__(self, directory):
        self.store = Store(directory)
        self.guard = threading.Lock()
        self.lease_guard = threading.RLock()
        self.session = None; self.generation = -1
        self.retired = set()
        self.cursor = ''; self.scope = None; self.last_anchor = ''; self.more = False

    def presence(self, active):
        try: d = self.store.directory(['.cache', 'caboose', 'bridge'])
        except FileNotFoundError: return
        try:
            if active:
                f = os.open('present', os.O_WRONLY | os.O_CREAT | os.O_NOFOLLOW | os.O_NONBLOCK, 0o600, dir_fd=d)
                try:
                    if not stat.S_ISREG(os.fstat(f).st_mode): raise ValueError('presence file')
                    os.utime(f, None)
                finally: os.close(f)
            else:
                try: os.unlink('present', dir_fd=d)
                except FileNotFoundError: pass
        finally: os.close(d)

    def lease(self, value):
        if not isinstance(value, dict) or not isinstance(value.get('session'), str) or not HEX.fullmatch(value['session']) or type(value.get('generation')) is not int or not 0 <= value['generation'] <= 2**53-1 or type(value.get('phone')) is not bool:
            raise ValueError('presence lease')
        with self.lease_guard:
            if value['session'] != self.session or value['generation'] < self.generation: return False
            self.generation = value['generation']
            self.presence(value['phone'])
            return True

    def serve(self, handler, value, changes, authorized):
        value = request(value)
        handler.close_connection = True
        if not self.guard.acquire(blocking=False): return handler.reply(409, {'error': 'event reader busy'})
        watch = None
        try:
            with self.lease_guard:
                if value['session'] in self.retired or (value['session'] == self.session and value['generation'] < self.generation): raise ValueError('stale event generation')
                if value['session'] != self.session:
                    if self.session: self.retired.add(self.session)
                    # Bound sessions; fail closed rather than reauthorizing a retired lease.
                    if len(self.retired) > 256: raise ValueError('service generation exhausted')
                    self.session = value['session']; self.generation = -1; self.cursor = ''
                    self.store.accepted_bridge.clear()
                self.generation = value['generation']
            if not value.get('cursor'): self.store.accepted_bridge.clear()
            for token in value.get('acks', []): self.store.ack(token)
            scope = encode([value['channels'], value.get('tasks', []), value['phone']])
            watch = Watch(self.store.directory, value.get('tasks', []))
            # Watch before snapshot, so racing publication always causes the next read.
            anchor = changes.anchor()
            dirty = value.get('cursor', '') != self.cursor or scope != self.scope or not self.cursor or self.more or anchor != self.last_anchor
            self.scope = scope
            deadline = time.monotonic() + 20
            while not dirty and time.monotonic() < deadline:
                if not authorized(): raise ValueError('expired service generation')
                ready, _, _ = select.select([watch.fd, changes.wake_read, handler.connection, *watch.processes], [], [], min(20, max(0, deadline-time.monotonic())))
                if handler.connection in ready: return  # Disconnect or pipelining: do not mutate any queue.
                if any(fd in ready for fd in watch.processes): dirty = True
                if changes.wake_read in ready:
                    os.read(changes.wake_read, 65536)
                    if changes.anchor() != self.last_anchor: dirty = True
                if watch.fd in ready:
                    dirty = dirty or Watch.changed(os.read(watch.fd, 65536))
                if 'fs' in value['channels'] and changes.anchor() != anchor: dirty = True
            if not authorized(): raise ValueError('expired service generation')
            self.last_anchor = changes.anchor()
            records, more = self.store.snapshot(value, self.last_anchor) if dirty else ([], False)
            self.more = more
            self.cursor = secrets.token_hex(16)
            handler.reply(200, {'cursor': self.cursor, 'records': records, 'more': more}, {'Cache-Control': 'no-store', 'Connection': 'close'})
        finally:
            if watch: watch.close()
            self.guard.release()
