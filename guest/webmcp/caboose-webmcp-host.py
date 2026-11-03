#!/usr/bin/env python3
"""Native messaging host com.caboose.webmcp (standard library only).

Chromium starts it for the Caboose WebMCP extension and talks to it over stdin/stdout, each
message a 32-bit native-endian length then UTF-8 JSON. It listens on a Unix socket named
after the browser process that started it,

    $XDG_RUNTIME_DIR/caboose-webmcp/<browser pid>.sock   (mode 0600, directory 0700)

so desktop MCP, which knows a window's process, reaches that browser's active tab. A client
sends one JSON request per line, { "op": "tools" } or { "op": "call", "name", "args" }, and
gets one JSON reply per line, { "ok", "result" | "error" }. The host ends when the browser
closes its stdin, and removes its socket."""
import json
import os
import socket
import struct
import sys
import threading

MAX_MESSAGE = 1024 * 1024  # Chromium refuses larger messages from a host
lock = threading.Lock()
pending = {}  # request id -> (event, [reply])
counter = [0]


def send(message):
    data = json.dumps(message).encode()
    if len(data) > MAX_MESSAGE:
        raise ValueError('request too large')
    with lock:
        sys.stdout.buffer.write(struct.pack('=I', len(data)) + data)
        sys.stdout.buffer.flush()


def browser_messages():
    """Replies from the extension, until the browser goes away."""
    stream = sys.stdin.buffer
    while True:
        head = stream.read(4)
        if len(head) < 4:
            return
        size = struct.unpack('=I', head)[0]
        body = stream.read(size)
        if len(body) < size:
            return
        try:
            message = json.loads(body)
        except ValueError:
            continue
        waiter = pending.pop(message.get('id'), None)
        if waiter:
            waiter[1].append(message)
            waiter[0].set()


def ask(request, timeout=25):
    with lock:
        counter[0] += 1
        ident = counter[0]
    event, box = threading.Event(), []
    pending[ident] = (event, box)
    send({'id': ident, 'op': request.get('op'), 'name': request.get('name'), 'args': request.get('args')})
    if not event.wait(timeout):
        pending.pop(ident, None)
        return {'ok': False, 'error': 'the browser did not answer'}
    reply = box[0]
    return {'ok': bool(reply.get('ok')), **({'result': reply['result']} if 'result' in reply else {}), **({'error': reply['error']} if 'error' in reply else {})}


def serve_client(conn):
    with conn, conn.makefile('rwb') as stream:
        for line in stream:
            try:
                request = json.loads(line)
                if request.get('op') not in ('tools', 'call') or (request['op'] == 'call' and not isinstance(request.get('name'), str)):
                    reply = {'ok': False, 'error': 'op must be tools or call (with a name)'}
                else:
                    reply = ask(request)
            except ValueError as error:
                reply = {'ok': False, 'error': str(error)}
            stream.write((json.dumps(reply) + '\n').encode())
            stream.flush()


def main():
    runtime = os.environ.get('XDG_RUNTIME_DIR') or f'/run/user/{os.getuid()}'
    directory = os.path.join(runtime, 'caboose-webmcp')
    os.makedirs(directory, mode=0o700, exist_ok=True)
    os.chmod(directory, 0o700)
    path = os.path.join(directory, f'{os.getppid()}.sock')
    try:
        os.unlink(path)
    except FileNotFoundError:
        pass
    server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    old = os.umask(0o177)
    try:
        server.bind(path)
    finally:
        os.umask(old)
    server.listen(4)

    def accept():
        while True:
            try:
                conn, _ = server.accept()
            except OSError:
                return
            threading.Thread(target=serve_client, args=(conn,), daemon=True).start()

    threading.Thread(target=accept, daemon=True).start()
    try:
        browser_messages()
    finally:
        server.close()
        try:
            os.unlink(path)
        except FileNotFoundError:
            pass


if __name__ == '__main__':
    main()
