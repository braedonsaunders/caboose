#!/usr/bin/env python3
"""Hosts a standalone GPU broker for the Linux executor, in place of the owner's display.

It starts guest/gpu/gfxstream/caboose-gpu-broker with its control socket and a fresh
per-wake token, accepts executor connections on a TCP port and hands each to the broker as
the display hands it the phone's relayed connection, and answers the broker's compositor
records: every surface bind is granted to the window it names, and every revoke request is
granted. It does not check that the bound process made the window, as the compositor does
(docs/gpu-live.md, "Window identity boundary"), so it is for disposable test computers only.

    python3 broker_host.py --directory DIR --listen 127.0.0.1:14650 [--bind-delay SECONDS]

--bind-delay answers each bind that much later, as a compositor waiting for a window's layer
does, so the queries an application makes before its window is bound are exercised.
SIGUSR1 replaces the broker with a new one, as a display restart does: the executor's session
and every guest stream end, and the executor may connect again.

DIR (created mode 0700) receives token, gpu.sock and surface.sock. Applications reach the
broker with CABOOSE_GFXSTREAM_SOCKET=DIR/gpu.sock and CABOOSE_GFXSTREAM_SURFACE_SOCKET=DIR/surface.sock.
"""
import argparse
import array
import os
from pathlib import Path
import select
import signal
import socket
import subprocess
import sys
import time

BROKER_DIR = Path(__file__).resolve().parents[5] / 'guest' / 'gpu' / 'gfxstream'
sys.path.insert(0, str(BROKER_DIR))
import control_protocol  # noqa: E402


def log(message):
    print('CABOOSE_BROKER_HOST ' + message, flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__.split('\n\n')[0])
    parser.add_argument('--directory', type=Path, required=True)
    parser.add_argument('--listen', default='127.0.0.1:14650', metavar='HOST:PORT')
    parser.add_argument('--broker', type=Path, default=BROKER_DIR / 'caboose-gpu-broker')
    parser.add_argument('--bind-delay', type=float, default=0.0, metavar='SECONDS')
    options = parser.parse_args()
    directory = options.directory
    directory.mkdir(mode=0o700, parents=True, exist_ok=True)
    os.chmod(directory, 0o700)
    token = directory / 'token'
    fd = os.open(token, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    os.write(fd, os.urandom(16).hex().encode())
    os.close(fd)
    # The broker's modules, as the installed launcher puts them on its path.
    modules = [str(options.broker.resolve().parent), str(BROKER_DIR.parent / 'broker')]

    def start_broker():
        parent, child = socket.socketpair(socket.AF_UNIX, socket.SOCK_SEQPACKET)
        broker = subprocess.Popen(
            [sys.executable, str(options.broker), '--control-fd=0', '--token-file', str(token),
             '--socket', str(directory / 'gpu.sock'), '--surface-socket', str(directory / 'surface.sock'),
             '--private-indexed'], stdin=child, env=dict(os.environ, PYTHONPATH=os.pathsep.join(modules)))
        child.close()
        return broker, parent

    def stop_broker(broker):
        if broker.poll() is None:
            broker.terminate()
            try:
                broker.wait(10)
            except subprocess.TimeoutExpired:
                broker.kill()
                broker.wait()

    broker, parent = start_broker()
    host, port = options.listen.rsplit(':', 1)
    listener = socket.socket()
    listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    listener.bind((host, int(port)))
    listener.listen(4)
    log(f'broker pid={broker.pid} listening on {options.listen} directory={directory}')
    epoch = os.urandom(16)
    generation = 0
    stopping = []
    restarts = []
    delayed = []  # (due, record bytes, log line) of bind results not yet answered
    signal.signal(signal.SIGTERM, lambda *_: stopping.append(True))
    signal.signal(signal.SIGINT, lambda *_: stopping.append(True))
    signal.signal(signal.SIGUSR1, lambda *_: restarts.append(True))
    try:
        while not stopping and broker.poll() is None:
            if restarts:
                restarts.clear()
                stop_broker(broker)
                parent.close()
                delayed.clear()
                broker, parent = start_broker()
                log(f'broker restarted pid={broker.pid}')
            now = time.monotonic()
            while delayed and delayed[0][0] <= now:
                _, data, line = delayed.pop(0)
                parent.sendall(data)
                log(line)
            timeout = 0.5 if not delayed else max(0.0, min(0.5, delayed[0][0] - now))
            try:
                ready, _, _ = select.select([listener, parent], [], [], timeout)
            except InterruptedError:
                continue
            if listener in ready:
                connection, peer = listener.accept()
                parent.sendmsg([b'G'], [(socket.SOL_SOCKET, socket.SCM_RIGHTS, array.array('i', [connection.fileno()]))])
                connection.close()
                log(f'executor connection from {peer[0]}:{peer[1]} handed to the broker')
            if parent in ready:
                raw, ancillary, flags, _ = parent.recvmsg(256, socket.CMSG_SPACE(4 * 4))
                if not raw:
                    break
                fds = array.array('i')
                for level, kind, data in ancillary:
                    if level == socket.SOL_SOCKET and kind == socket.SCM_RIGHTS:
                        fds.frombytes(data[:len(data) - len(data) % fds.itemsize])
                try:
                    record = control_protocol.decode(raw, len(fds))
                finally:
                    for fd in fds:
                        os.close(fd)
                if isinstance(record, control_protocol.Bind):
                    generation += 1
                    grant = os.urandom(16)
                    data = control_protocol.encode_result(control_protocol.BindResult(
                        record.request, 0, epoch, grant, record.object_id, generation))
                    line = (f'bind granted process={record.process} pid={record.pid} object={record.object_id:#x} '
                            f'space={record.space} generation={generation}')
                    delayed.append((time.monotonic() + options.bind_delay, data, line))
                elif isinstance(record, control_protocol.RevokeRequest):
                    parent.sendall(control_protocol.encode_revoke(control_protocol.RevokeGrant(
                        record.epoch, record.grant, record.generation)))
                    log(f'revoke granted generation={record.generation}')
                elif isinstance(record, control_protocol.GrantRetired):
                    log(f'grant retired generation={record.generation}')
                elif isinstance(record, control_protocol.ExecutorLifecycle):
                    log({4: 'executor ready', 5: 'executor lost', 6: 'executor retired'}[record.kind] +
                        f' generation={record.generation}')
                else:
                    log(f'control record {record!r}')
    finally:
        listener.close()
        parent.close()
        stop_broker(broker)
        log(f'broker exited {broker.returncode}')


if __name__ == '__main__':
    main()
