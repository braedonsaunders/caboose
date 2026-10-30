#!/usr/bin/env python3
"""A stand-in for the Caboose VA-API driver (guest/vaapi), for checking the
compositor's side of video passthrough without a real decoder.

It speaks the driver's socket protocol (guest/vaapi/src/proto.h): HELLO, OPEN of one
H.264 stream, and FRAME for every access unit of a real clip at its frame rate. Like a
browser whose GPU process decodes, it then starts Chromium as its child, showing a page
that paints the marker for the tag the compositor assigned.

    fake-video-driver.py SECONDS [CHROMIUM ARGS...]
"""
import os
import socket
import struct
import subprocess
import sys
import tempfile
import time

HERE = os.path.dirname(os.path.abspath(__file__))


def clip(seconds):
    """An H.264 clip split into access units (x264 writes an AUD before each)."""
    out = os.path.join(tempfile.mkdtemp(), "clip.h264")
    subprocess.run(["ffmpeg", "-loglevel", "error", "-y", "-f", "lavfi", "-i", f"testsrc2=size=640x360:rate=30:duration={seconds}",
                    "-c:v", "libx264", "-preset", "ultrafast", "-pix_fmt", "yuv420p", "-x264-params", "aud=1:keyint=30:bframes=0",
                    "-f", "h264", out], check=True)
    data = open(out, "rb").read()
    aud = b"\x00\x00\x00\x01\x09"
    starts = [i for i in range(len(data)) if data.startswith(aud, i)]
    units = [data[a:b] for a, b in zip(starts, starts[1:] + [len(data)])]
    def key(u):
        i = 0
        while True:
            i = u.find(b"\x00\x00\x01", i)
            if i < 0:
                return False
            if u[i + 3] & 0x1f == 5:
                return True
            i += 3
    return [(u, key(u)) for u in units]


def message(t, payload):
    return bytes([t]) + struct.pack("<I", len(payload)) + payload


def main():
    seconds = int(sys.argv[1])
    units = clip(seconds + 2)
    path = os.environ.get("CABOOSE_VIDEO_SOCKET") or os.path.join(os.environ["XDG_RUNTIME_DIR"], "caboose-video.sock")
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.connect(path)
    s.sendall(message(0x01, struct.pack("<HHI", 1, 0, os.getpid()) + b"fake-video-driver"))
    s.sendall(message(0x02, struct.pack("<IBBBBHH", 1, 1, 100, 8, 1, 640, 360)))
    reply = s.recv(64)
    if len(reply) < 11 or reply[0] != 0x81:
        sys.exit(f"no ACCEPT: {reply!r}")
    stream, tag, mode = struct.unpack("<IBB", reply[5:11])
    print(f"ACCEPT stream {stream} tag {tag} mode {mode}", flush=True)
    if mode != 0:
        sys.exit("local decode requested: legacy marker fixture requires passthrough admission")
    page = f"file://{HERE}/pages/marker.html?tag={tag}&fps=30&x=100&y=80&w=640&h=360"
    browser = subprocess.Popen(sys.argv[2:] + [f"--app={page}"])
    start = time.time()
    for seq, (unit, key) in enumerate(units):
        due = start + seq / 30
        time.sleep(max(0, due - time.time()))
        if time.time() - start > seconds:
            break
        t_us = int(time.monotonic() * 1e6)
        s.sendall(message(0x03, struct.pack("<IIIB3xQHH", 1, seq, seq % 8, 1 if key else 0, t_us, 640, 360) + unit))
    s.sendall(message(0x05, struct.pack("<IB", 1, 0)))
    browser.terminate()
    browser.wait()


if __name__ == "__main__":
    main()
