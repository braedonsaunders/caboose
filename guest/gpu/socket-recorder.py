#!/usr/bin/python3
"""Stand in for the GPU broker's two sockets and record which processes open them.

socket-recorder.py GPU_SOCKET SURFACE_SOCKET LOG

Each connection is read for at most its first 64 bytes (the driver's hello), recorded as
one JSON line (socket, peer pid, its command name and command line, the first 16 bytes in
hex) and closed, as the broker closes a connection it does not accept: the driver then
fails its Vulkan instance and the application continues on the computer's own drivers.
It runs until killed. check-apps.sh uses it; it is not part of a computer.
"""
import json
import os
import socket
import struct
import sys
import threading


def proc(pid, name):
    try:
        with open(f'/proc/{pid}/{name}', 'rb') as f:
            return f.read().replace(b'\0', b' ').decode(errors='replace').strip()
    except OSError:
        return ''


def serve(path, kind, log, lock):
    try:
        os.unlink(path)
    except FileNotFoundError:
        pass
    listener = socket.socket(socket.AF_UNIX, kind)
    listener.bind(path)
    os.chmod(path, 0o600)
    listener.listen(64)
    while True:
        connection, _ = listener.accept()
        with connection:
            pid = struct.unpack('3i', connection.getsockopt(socket.SOL_SOCKET, socket.SO_PEERCRED, 12))[0]
            connection.settimeout(2)
            try:
                hello = connection.recv(64)
            except OSError:
                hello = b''
            record = dict(socket=os.path.basename(path), pid=pid, comm=proc(pid, 'comm'),
                          cmdline=proc(pid, 'cmdline')[:400], hello=hello[:16].hex())
        with lock:
            log.write(json.dumps(record) + '\n')
            log.flush()


def main(argv):
    if len(argv) != 3:
        sys.exit(__doc__.split('\n\n')[1])
    log, lock = open(argv[2], 'a', encoding='utf-8'), threading.Lock()
    threading.Thread(target=serve, args=(argv[0], socket.SOCK_STREAM, log, lock), daemon=True).start()
    serve(argv[1], socket.SOCK_SEQPACKET, log, lock)


if __name__ == '__main__':
    main(sys.argv[1:])
