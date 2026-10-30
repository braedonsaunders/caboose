#!/usr/bin/env python3
"""Finite private TLS/Unix bridge; no Vulkan interpretation or fabricated replies."""
import argparse
import hashlib
import hmac
import ipaddress
import json
import os
from pathlib import Path
import select
import socket
import ssl
import stat
import struct
import time

MAGIC = b"CBGTLS01"
CHUNK = 65536
MAX_BYTES = 128 * 1024 * 1024


def auth_record(session, generation, token):
    if len(session) != 16 or not any(session) or not 0 < generation < 2**64 or len(token) != 32:
        raise ValueError("invalid diagnostic identity")
    return MAGIC + session + generation.to_bytes(8, "big") + token


def receive_exact(stream, size, deadline):
    result = bytearray()
    while len(result) < size:
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            raise TimeoutError("authentication timeout")
        stream.settimeout(remaining)
        data = stream.recv(size - len(result))
        if not data:
            raise ConnectionError("authentication EOF")
        result.extend(data)
    return bytes(result)


def relay(guest, phone, deadline, max_bytes=MAX_BYTES):
    """Single-threaded SSL ownership; at most one 64 KiB queue per direction."""
    guest.setblocking(False)
    phone.setblocking(False)
    to_phone, to_guest = bytearray(), bytearray()
    counts = [0, 0]
    ended = False
    while True:
        if time.monotonic() >= deadline:
            raise TimeoutError("relay deadline")
        tls_write_needed = False
        progressed = False
        for dest, pending in ((phone, to_phone), (guest, to_guest)):
            if not pending:
                continue
            try:
                count = dest.send(pending)
                if count == 0:
                    raise ConnectionError("relay send EOF")
                del pending[:count]
                progressed = True
            except ssl.SSLWantWriteError:
                tls_write_needed = True
            except (ssl.SSLWantReadError, BlockingIOError):
                pass
        if not ended:
            for index, source, pending in ((0, guest, to_phone), (1, phone, to_guest)):
                if len(pending) == CHUNK:
                    continue
                try:
                    data = source.recv(CHUNK - len(pending))
                    if not data:
                        ended = True
                        break
                    counts[index] += len(data)
                    if sum(counts) > max_bytes:
                        raise ValueError("diagnostic byte budget exceeded")
                    pending.extend(data)
                    progressed = True
                except ssl.SSLWantWriteError:
                    tls_write_needed = True
                except (ssl.SSLWantReadError, BlockingIOError):
                    pass
        if ended and not to_phone and not to_guest:
            return {"guest_bytes": counts[0], "phone_bytes": counts[1]}
        if not progressed:
            readers = [] if ended else [s for s, p in ((guest, to_phone), (phone, to_guest)) if len(p) < CHUNK]
            # SSL writes can require an incoming TLS control record.
            if to_phone and phone not in readers:
                readers.append(phone)
            writers = ([guest] if to_guest else []) + ([phone] if to_phone or tls_write_needed else [])
            select.select(readers, writers, [], min(0.05, max(0, deadline - time.monotonic())))


def private_directory(path):
    info = path.lstat()
    if not stat.S_ISDIR(info.st_mode) or info.st_uid != os.geteuid() or stat.S_IMODE(info.st_mode) != 0o700:
        raise ValueError("socket directory must be owned by caller and mode 0700")


def secret_file(path, size=None):
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
    with os.fdopen(fd, "rb") as source:
        info = os.fstat(source.fileno())
        if not stat.S_ISREG(info.st_mode) or info.st_uid != os.geteuid() or stat.S_IMODE(info.st_mode) & 0o077:
            raise ValueError("private input must be an owned private regular file")
        data = source.read(65537)
    if len(data) > 65536 or (size is not None and len(data) != size):
        raise ValueError("invalid private input size")
    return data


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--bind", required=True, help="explicit private/VPN IPv4 address")
    parser.add_argument("--port", type=int, default=0)
    parser.add_argument("--directory", type=Path, required=True)
    parser.add_argument("--cert", type=Path, required=True)
    parser.add_argument("--key", type=Path, required=True)
    parser.add_argument("--token", type=Path, required=True, help="private file of 32 random bytes")
    parser.add_argument("--session", required=True, help="nonzero 16-byte session ID as hex")
    parser.add_argument("--generation", required=True, type=int)
    parser.add_argument("--seconds", type=int, default=90)
    args = parser.parse_args()
    address = ipaddress.IPv4Address(args.bind)
    if address.is_unspecified or address.is_multicast or not (address.is_private or address in ipaddress.ip_network("100.64.0.0/10")):
        raise ValueError("bind must select one private/VPN address")
    if not 1 <= args.seconds <= 90 or not 0 <= args.port <= 65535:
        raise ValueError("invalid bounded endpoint")
    private_directory(args.directory)
    token = secret_file(args.token, 32)
    secret_file(args.key)
    expected = auth_record(bytes.fromhex(args.session), args.generation, token)
    pem = args.cert.read_text()
    pin = hashlib.sha256(ssl.PEM_cert_to_DER_cert(pem)).hexdigest()
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    context.minimum_version = ssl.TLSVersion.TLSv1_3
    context.maximum_version = ssl.TLSVersion.TLSv1_3
    context.load_cert_chain(args.cert, args.key)
    deadline = time.monotonic() + args.seconds
    unix_path = args.directory / "guest.sock"
    if unix_path.exists() or unix_path.is_symlink():
        raise FileExistsError("guest socket already exists")
    bound_unix = False
    try:
        with socket.socket(socket.AF_INET) as listener, socket.socket(socket.AF_UNIX) as local:
            listener.bind((args.bind, args.port))
            listener.listen(1)
            listener.settimeout(max(0.001, deadline - time.monotonic()))
            print(json.dumps({"event": "listening", "port": listener.getsockname()[1], "certificate_sha256": pin}), flush=True)
            raw, _ = listener.accept()
            with raw:
                raw.settimeout(min(5, max(0.001, deadline - time.monotonic())))
                with context.wrap_socket(raw, server_side=True) as phone:
                    record = receive_exact(phone, 64, min(deadline, time.monotonic() + 5))
                    if not hmac.compare_digest(record, expected):
                        phone.sendall(b"\x01")
                        raise PermissionError("diagnostic authentication rejected")
                    phone.sendall(b"\x00")
                    local.bind(str(unix_path))
                    bound_unix = True
                    os.chmod(unix_path, 0o600)
                    local.listen(1)
                    local.settimeout(max(0.001, deadline - time.monotonic()))
                    print(json.dumps({"event": "authenticated", "guest_socket": str(unix_path)}), flush=True)
                    guest, _ = local.accept()
                    with guest:
                        _, uid, _ = struct.unpack("3i", guest.getsockopt(socket.SOL_SOCKET, socket.SO_PEERCRED, 12))
                        if uid != os.geteuid():
                            raise PermissionError("guest UID rejected")
                        result = relay(guest, phone, deadline)
                        print(json.dumps({"event": "finished", **result}), flush=True)
    finally:
        if bound_unix:
            unix_path.unlink(missing_ok=True)


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError) as error:
        # Never echo exception text: path/configuration values can be private.
        print(json.dumps({"event": "failed", "error_type": type(error).__name__}), flush=True)
        raise SystemExit(1)
