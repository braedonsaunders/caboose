#!/usr/bin/env python3
"""Check an already-running Cloud Hypervisor VM's Files vsock bridge."""
import argparse
import socket

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('vsock_socket', help='Cloud Hypervisor Unix vsock socket for the running computer')
args = parser.parse_args()
with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as sock:
    sock.settimeout(10)
    sock.connect(args.vsock_socket)
    sock.sendall(b'CONNECT 14700\n')
    banner = b''
    while not banner.endswith(b'\n'):
        chunk = sock.recv(1)
        if not chunk or len(banner) >= 128:
            raise RuntimeError('Invalid or missing vsock handshake')
        banner += chunk
    if not banner.startswith(b'OK '):
        raise RuntimeError(f'Vsock connection refused: {banner!r}')
    sock.sendall(b'GET / HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n')
    response = sock.recv(256)
    if not response.startswith(b'HTTP/1.'):
        raise RuntimeError(f'Files service did not answer HTTP: {response!r}')
    print('Files service answered through vsock:', response.split(b'\r\n', 1)[0].decode('ascii', 'replace'))
