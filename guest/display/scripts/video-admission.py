#!/usr/bin/env python3
"""Assert marker streams request local decode, with or without client codecs.
Run as an isolated compositor child (scripts/check.py passthrough). No media or
owner data is read. Every socket read and the overall sampling period is bounded.
"""
import json
import os
import socket
import struct
import sys
import time


def exact(sock, length):
    out = bytearray()
    while len(out) < length:
        part = sock.recv(length - len(out))
        if not part:
            raise RuntimeError("driver socket closed")
        out.extend(part)
    return bytes(out)


def check(path):
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as sock:
        sock.settimeout(2)
        sock.connect(path)
        def send(kind, payload):
            sock.sendall(bytes([kind]) + struct.pack("<I", len(payload)) + payload)
        send(1, struct.pack("<HHI", 1, 0, os.getpid()) + b"admission-check")
        for codec in (1, 2, 3, 4):
            send(2, struct.pack("<IBBBBHH", codec, codec, 0, 8, 1, 640, 360))
            kind, size = struct.unpack("<BI", exact(sock, 5))
            if kind != 0x81 or size != 6:
                raise RuntimeError(f"expected ACCEPT, got type={kind} length={size}")
            stream, tag, mode = struct.unpack("<IBB", exact(sock, size))
            if stream != codec or mode != 1:
                raise RuntimeError(f"unsafe marker admission codec={codec} mode={mode}")
            send(5, struct.pack("<IB", codec, 0))


def main():
    path = os.environ.get("CABOOSE_VIDEO_SOCKET") or os.path.join(os.environ["XDG_RUNTIME_DIR"], "caboose-video.sock")
    deadline = time.monotonic() + 12
    rounds = 0
    def record(status, error=None):
        with open(sys.argv[1] + ".part", "w") as out:
            json.dump({"rounds": rounds, "status": status, "error": error}, out)
        os.replace(sys.argv[1] + ".part", sys.argv[1])
    try:
        while time.monotonic() < deadline:
            check(path)
            rounds += 1
            record("running")
            time.sleep(0.1)
        record("complete")
    except Exception as error:
        record("failed", str(error))
        raise



if __name__ == "__main__":
    main()
