#!/usr/bin/env python3
"""Plays a phone against the owner's Caboose Display and checks that its hardware becomes
the computer's devices (docs/devices.md), through the kernel's own interfaces:

  gamepad    evdev keys and sticks; a rumble effect played by an application arrives
             as device.rumble
  buttons    evdev key presses
  motion     the evdev device opens motion (device.open at 100 Hz) and reads samples;
             the IIO accelerometer's buffer opens it too and reads the sample in its scale
  battery    the power supply's capacity and status
  camera     ffmpeg reading /dev/videoN opens the camera; the phone's H.264 test picture
             arrives as YUYV; closing it sends device.close
  depth      ffmpeg reads the depth picture the phone sent
  microphone parec recording from the phone's source opens it and records its tone
  disconnect closing the connection removes what nothing uses

Run as root inside a computer whose owner's display is running (the host has woken it),
with the phone disconnected (this check takes the display, as a new phone would):

  sudo python3 guest/display/scripts/check-devices.py [--port 14600] [--only KIND,...]

It needs ffmpeg (libx264, libopus), pulseaudio-utils and python3-websockets, all in the
image. Each kind passes, fails, or is reported unavailable with the computer's reason;
unavailable fails unless named in --allow-unavailable.
"""

import argparse
import array
import fcntl
import glob
import math
import os
import select
import struct
import subprocess
import sys
import tempfile
import threading
import time

from websockets.sync.client import connect

TOKEN = "/run/caboose/display-token"
DISPLAY_ENV = "/run/caboose/display.env"

# ---- CBOR, the subset the protocol uses ----


def cbor_head(major, n):
    if n < 24:
        return bytes([major << 5 | n])
    for info, size in ((24, 1), (25, 2), (26, 4), (27, 8)):
        if n < 1 << (8 * size):
            return bytes([major << 5 | info]) + n.to_bytes(size, "big")
    raise ValueError(n)


def cbor(v):
    if isinstance(v, bool):
        return b"\xf5" if v else b"\xf4"
    if isinstance(v, int):
        return cbor_head(0, v) if v >= 0 else cbor_head(1, -1 - v)
    if isinstance(v, float):
        return b"\xfb" + struct.pack(">d", v)
    if isinstance(v, bytes):
        return cbor_head(2, len(v)) + v
    if isinstance(v, str):
        b = v.encode()
        return cbor_head(3, len(b)) + b
    if isinstance(v, (list, tuple)):
        return cbor_head(4, len(v)) + b"".join(cbor(x) for x in v)
    if isinstance(v, dict):
        items = sorted(((cbor(k), cbor(x)) for k, x in v.items()), key=lambda kv: (len(kv[0]), kv[0]))
        return cbor_head(5, len(items)) + b"".join(k + x for k, x in items)
    raise TypeError(type(v))


def uncbor(b, i=0):
    first = b[i]
    major, info = first >> 5, first & 31
    i += 1
    if major == 7:
        if info == 20:
            return False, i
        if info == 21:
            return True, i
        if info == 22:
            return None, i
        if info == 25:
            h = int.from_bytes(b[i:i + 2], "big")
            e, m = (h >> 10) & 31, h & 1023
            v = m * 2.0 ** -24 if e == 0 else (m + 1024) * 2.0 ** (e - 25) if e < 31 else math.inf
            return (-v if h & 0x8000 else v), i + 2
        if info == 26:
            return struct.unpack(">f", b[i:i + 4])[0], i + 4
        if info == 27:
            return struct.unpack(">d", b[i:i + 8])[0], i + 8
        raise ValueError(first)
    if info < 24:
        n = info
    else:
        size = {24: 1, 25: 2, 26: 4, 27: 8}[info]
        n, i = int.from_bytes(b[i:i + size], "big"), i + size
    if major == 0:
        return n, i
    if major == 1:
        return -1 - n, i
    if major == 2:
        return bytes(b[i:i + n]), i + n
    if major == 3:
        return b[i:i + n].decode(), i + n
    if major == 4:
        out = []
        for _ in range(n):
            x, i = uncbor(b, i)
            out.append(x)
        return out, i
    if major == 5:
        out = {}
        for _ in range(n):
            k, i = uncbor(b, i)
            x, i = uncbor(b, i)
            out[k] = x
        return out, i
    if major == 6:
        return uncbor(b, i)
    raise ValueError(first)


# ---- the display connection ----

NAMES = {0x01: "hello", 0x02: "window.create", 0x7F: "bye", 0x7E: "pong", 0x60: "device.status",
         0x61: "device.open", 0x62: "device.close", 0x63: "device.rumble", 0x64: "device.keyframe"}
TYPES = {"hello": 0x81, "ping": 0xFE, "devices": 0xB0, "device.camera": 0xB1, "device.depth": 0xB2,
         "device.audio": 0xB3, "device.motion": 0xB4, "device.gamepad": 0xB5, "device.button": 0xB6,
         "device.battery": 0xB7}


class Phone:
    """A phone on the owner's display: sends messages and collects the device ones."""

    def __init__(self, port, token_file=TOKEN, expect_devices=True):
        token = open(token_file).read().strip()
        self.ws = connect(f"ws://127.0.0.1:{port}/", subprotocols=["binary"], max_size=None, open_timeout=10)
        self.buffer = b""
        self.messages = []
        self.cond = threading.Condition()
        self.closed = False
        self.send("hello", {"version": 0, "token": token, "decoders": ["h264", "hevc"],
                            "displays": [{"id": 1, "width": 1179, "height": 2556, "scale": 3.0,
                                          "refresh_hz": 60.0, "hdr": False}],
                            "devices": True})
        threading.Thread(target=self.read, daemon=True).start()
        threading.Thread(target=self.keepalive, daemon=True).start()
        hello = self.wait(lambda m: m[0] == "hello", 10)
        if ("devices" in hello[1].get("features", [])) != expect_devices:
            self.close()
            raise Failed(f"the display does not accept devices (features {hello[1].get('features')})")

    def send(self, name, fields):
        payload = cbor(fields)
        self.ws.send(bytes([TYPES[name]]) + struct.pack("<I", len(payload)) + payload)

    def read(self):
        try:
            for data in self.ws:
                self.buffer += data
                while len(self.buffer) >= 5:
                    kind, length = self.buffer[0], struct.unpack("<I", self.buffer[1:5])[0]
                    if len(self.buffer) < 5 + length:
                        break
                    payload, self.buffer = self.buffer[5:5 + length], self.buffer[5 + length:]
                    if kind in NAMES:
                        with self.cond:
                            self.messages.append((NAMES[kind], uncbor(payload)[0]))
                            self.cond.notify_all()
        except Exception:
            pass
        with self.cond:
            self.closed = True
            self.cond.notify_all()

    def keepalive(self):
        while not self.closed:
            try:
                self.send("ping", {"t_us": int(time.monotonic() * 1e6)})
            except Exception:
                return
            time.sleep(5)

    def wait(self, match, seconds, what="a message"):
        deadline = time.monotonic() + seconds
        with self.cond:
            while True:
                for i, m in enumerate(self.messages):
                    if match(m):
                        return self.messages.pop(i)
                left = deadline - time.monotonic()
                if left <= 0 or self.closed:
                    raise Failed(f"no {what} within {seconds} s")
                self.cond.wait(left)

    def device_message(self, name, device, seconds, **fields):
        def match(m):
            return m[0] == name and m[1].get("device") == device and all(m[1].get(k) == v for k, v in fields.items())
        return self.wait(match, seconds, f"{name} for {device}")

    def close(self):
        self.ws.close()


class Failed(Exception):
    pass


class Unavailable(Exception):
    pass


# ---- evdev ----

EV_SYN, EV_KEY, EV_ABS, EV_FF = 0, 1, 3, 0x15
BTN_A, KEY_VOLUMEUP, KEY_CAMERA = 0x130, 115, 212
ABS_X, ABS_Z = 0, 2
EVENT = struct.Struct("llHHi")
FF_RUMBLE = 0x50


def ioc(direction, kind, nr, size):
    return direction << 30 | size << 16 | ord(kind) << 8 | nr


def read_events(fd, seconds, want):
    """Reads input events until `want(events)` holds; returns them."""
    events = []
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        r, _, _ = select.select([fd], [], [], max(0, deadline - time.monotonic()))
        if not r:
            break
        data = os.read(fd, EVENT.size * 64)
        for off in range(0, len(data) - EVENT.size + 1, EVENT.size):
            _, _, kind, code, value = EVENT.unpack_from(data, off)
            events.append((kind, code, value))
        if want(events):
            return events
    raise Failed(f"expected events did not arrive (got {events[-12:]})")


def check_mode(node):
    # Actually open as the owner: root's stat/access cannot prove ACLs and membership.
    subprocess.run(["runuser", "-u", "caboose", "--", "python3", "-c",
                    "import os,sys; fd=os.open(sys.argv[1], os.O_RDWR|os.O_NONBLOCK); os.close(fd)",
                    node], check=True, timeout=5, capture_output=True)


# ---- the checks ----

DEVICES = [
    {"id": "check-camera", "kind": "camera", "name": "Check Camera", "position": "back", "size": [320, 240], "fps": 30.0},
    {"id": "check-depth", "kind": "depth", "name": "Check Depth", "position": "back", "size": [256, 192], "fps": 15.0},
    {"id": "check-microphone", "kind": "microphone", "name": "Check Microphone"},
    {"id": "check-motion", "kind": "motion", "name": "Check Motion Sensors",
     "sensors": ["accelerometer", "gyroscope", "magnetometer", "rotation", "pressure"]},
    {"id": "check-gamepad", "kind": "gamepad", "name": "Check Controller", "rumble": True},
    {"id": "check-buttons", "kind": "buttons", "name": "Check Buttons", "keys": ["volume-up", "camera", "action"]},
    {"id": "check-battery", "kind": "battery", "name": "Check Battery"},
]


def status_of(phone, seconds=4):
    """The latest device.status after the kernel has finished making nodes."""
    status = {}
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        try:
            m = phone.wait(lambda m: m[0] == "device.status", max(0.1, deadline - time.monotonic()))
            status = {d["id"]: d for d in m[1]["devices"]}
        except Failed:
            break
    return status


def node(status, device, prefix):
    entry = status.get(device, {})
    found = [n for n in entry.get("nodes", []) if n.startswith(prefix)]
    if not found:
        raise Unavailable(entry.get("error") or f"no {prefix} node")
    return found[0]


def check_gamepad(phone, status):
    path = node(status, "check-gamepad", "/dev/input/event")
    check_mode(path)
    fd = os.open(path, os.O_RDWR | os.O_NONBLOCK)
    try:
        phone.send("device.gamepad", {"device": "check-gamepad", "buttons": 1, "axes": [1.0, 0.0, 0.0, 0.0, 0.0, 1.0]})
        read_events(fd, 3, lambda ev: (EV_KEY, BTN_A, 1) in ev and (EV_ABS, ABS_X, 32767) in ev)
        # An application's rumble: EVIOCSFF uploads it, writing EV_FF plays it.
        effect = struct.pack("HhHHHHH", FF_RUMBLE, -1, 0, 0, 0, 250, 0) + b"\0\0" + struct.pack("HH", 0xFFFF, 0x4000) + bytes(28)
        assert len(effect) == 48
        buf = bytearray(effect)
        fcntl.ioctl(fd, ioc(1, "E", 0x80, 48), buf)
        effect_id = struct.unpack_from("h", buf, 2)[0]
        os.write(fd, EVENT.pack(0, 0, EV_FF, effect_id, 1))
        m = phone.device_message("device.rumble", "check-gamepad", 3)
        if not (abs(m[1]["strong"] - 1.0) < 0.01 and abs(m[1]["weak"] - 0x4000 / 0xFFFF) < 0.01 and m[1]["ms"] == 250):
            raise Failed(f"rumble arrived as {m[1]}")
    finally:
        os.close(fd)


def check_buttons(phone, status):
    path = node(status, "check-buttons", "/dev/input/event")
    check_mode(path)
    fd = os.open(path, os.O_RDONLY | os.O_NONBLOCK)
    try:
        for key, code in (("volume-up", KEY_VOLUMEUP), ("camera", KEY_CAMERA)):
            phone.send("device.button", {"device": "check-buttons", "key": key, "pressed": True})
            phone.send("device.button", {"device": "check-buttons", "key": key, "pressed": False})
            read_events(fd, 3, lambda ev, c=code: (EV_KEY, c, 1) in ev and (EV_KEY, c, 0) in ev)
    finally:
        os.close(fd)


FACE_UP = {"t_us": 1, "accel": [0.0, 0.0, 9.80665], "gyro": [0.0, 0.0, 0.0], "magnet": [21.5, 0.0, -40.0],
           "rotation": [0.0, 0.0, 0.0, 1.0], "pressure": 101.325}


def check_motion(phone, status):
    path = node(status, "check-motion", "/dev/input/event")
    check_mode(path)
    fd = os.open(path, os.O_RDONLY | os.O_NONBLOCK)
    try:
        opened = phone.device_message("device.open", "check-motion", 3)
        if opened[1].get("rate_hz") != 100.0:
            raise Failed(f"motion opened at {opened[1].get('rate_hz')} Hz")
        phone.send("device.motion", {"device": "check-motion", "samples": [FACE_UP]})
        read_events(fd, 3, lambda ev: (EV_ABS, ABS_Z, 8192) in ev)
    finally:
        os.close(fd)
    phone.device_message("device.close", "check-motion", 4)


def check_iio(phone, status):
    entry = status.get("check-motion", {})
    names = {}
    for dev in entry.get("nodes", []):
        if dev.startswith("iio:device"):
            names[open(f"/sys/bus/iio/devices/{dev}/name").read().strip()] = dev
    expected = {"accel_3d", "gyro_3d", "magn_3d", "dev_rotation", "press"}
    if not expected <= names.keys():
        raise Unavailable(entry.get("error") or f"IIO devices {sorted(names)}, expected {sorted(expected)}")
    dev = names["accel_3d"]
    sysfs = f"/sys/bus/iio/devices/{dev}"
    scale = float(open(f"{sysfs}/in_accel_scale").read())
    for axis in "xyz":
        open(f"{sysfs}/scan_elements/in_accel_{axis}_en", "w").write("1")
    open(f"{sysfs}/buffer/length", "w").write("16")
    open(f"{sysfs}/buffer/enable", "w").write("1")
    try:
        phone.device_message("device.open", "check-motion", 4)
        fd = os.open(f"/dev/{dev}", os.O_RDONLY | os.O_NONBLOCK)
        try:
            deadline = time.monotonic() + 3
            data = b""
            while time.monotonic() < deadline and len(data) < 12:
                phone.send("device.motion", {"device": "check-motion", "samples": [FACE_UP]})
                r, _, _ = select.select([fd], [], [], 0.2)
                if r:
                    data += os.read(fd, 4096)
            if len(data) < 12:
                raise Failed("the accelerometer's buffer produced no sample")
            z = struct.unpack_from("<i", data, 8)[0] * scale
            if abs(z - 9.80665) > 0.01:
                raise Failed(f"accelerometer z read {z} m/s², sent 9.80665")
        finally:
            os.close(fd)
    finally:
        open(f"{sysfs}/buffer/enable", "w").write("0")
        for axis in "xyz":
            open(f"{sysfs}/scan_elements/in_accel_{axis}_en", "w").write("0")
    phone.device_message("device.close", "check-motion", 4)


def check_battery(phone, status):
    path = node(status, "check-battery", "/sys/class/power_supply/")
    phone.send("device.battery", {"device": "check-battery", "level": 0.75, "charging": True, "full": False,
                                  "low_power": False, "thermal": "fair"})
    deadline = time.monotonic() + 3
    while time.monotonic() < deadline:
        capacity = open(f"{path}/capacity").read().strip()
        state = open(f"{path}/status").read().strip()
        scope = open(f"{path}/scope").read().strip()
        if (capacity, state, scope) == ("75", "Charging", "Device"):
            return
        time.sleep(0.2)
    raise Failed(f"battery reads {capacity}% {state}, scope {scope}")


def h264_test_picture(size):
    w, h = size
    out = subprocess.run(["ffmpeg", "-loglevel", "error", "-f", "lavfi", "-i", f"testsrc=size={w}x{h}:rate=30",
                          "-frames:v", "1", "-c:v", "libx264", "-pix_fmt", "yuv420p", "-bsf:v", "h264_mp4toannexb",
                          "-f", "h264", "-"], check=True, capture_output=True, timeout=15)
    return out.stdout


def grab(path, pix_fmt, seconds=8):
    return subprocess.Popen(["ffmpeg", "-loglevel", "error", "-f", "v4l2", "-i", path, "-frames:v", "3",
                             "-f", "rawvideo", "-pix_fmt", pix_fmt, "-"],
                            stdout=subprocess.PIPE, stderr=subprocess.PIPE)


def check_camera(phone, status):
    path = node(status, "check-camera", "/dev/video")
    check_mode(path)
    picture = h264_test_picture((320, 240))
    reader = grab(path, "yuyv422")
    try:
        phone.device_message("device.open", "check-camera", 5)
        for seq in range(10):
            phone.send("device.camera", {"device": "check-camera", "seq": seq, "keyframe": True,
                                         "t_us": int(time.monotonic() * 1e6), "data": picture})
            time.sleep(0.05)
        out, err = reader.communicate(timeout=10)
    finally:
        if reader.poll() is None:
            reader.kill()
        reader.communicate(timeout=3)
    frame = out[-320 * 240 * 2:]
    if len(frame) < 320 * 240 * 2:
        raise Failed(f"ffmpeg read {len(out)} bytes: {err.decode().strip()}")
    luma = frame[0::2]
    if max(luma) - min(luma) < 100:
        raise Failed("the camera delivered a flat picture, not the test picture")
    phone.device_message("device.close", "check-camera", 5)


def check_depth(phone, status):
    path = node(status, "check-depth", "/dev/video")
    check_mode(path)
    reader = grab(path, "gray16le")
    try:
        phone.device_message("device.open", "check-depth", 5)
        depth = array.array("H", (1000 + (i % 256) for i in range(256 * 192))).tobytes()
        for _ in range(10):
            phone.send("device.depth", {"device": "check-depth", "t_us": int(time.monotonic() * 1e6),
                                        "size": [256, 192], "data": depth})
            time.sleep(0.07)
        out, err = reader.communicate(timeout=10)
    finally:
        if reader.poll() is None:
            reader.kill()
        reader.communicate(timeout=3)
    frame = out[-256 * 192 * 2:]
    if frame != depth:
        raise Failed(f"the depth picture did not arrive unchanged ({len(out)} bytes; {err.decode().strip()})")
    phone.device_message("device.close", "check-depth", 5)


def opus_packets(seconds, frequency):
    """20 ms mono Opus packets of a tone, taken out of ffmpeg's Ogg."""
    ogg = subprocess.run(["ffmpeg", "-loglevel", "error", "-f", "lavfi", "-i", f"sine=f={frequency}:r=48000",
                          "-t", str(seconds), "-ac", "1", "-c:a", "libopus", "-frame_duration", "20", "-f", "ogg", "-"],
                         check=True, capture_output=True, timeout=15).stdout
    packets, partial, i = [], b"", 0
    while i + 27 <= len(ogg) and ogg[i:i + 4] == b"OggS":
        segments = ogg[i + 26]
        table = ogg[i + 27:i + 27 + segments]
        body = i + 27 + segments
        for lace in table:
            partial += ogg[body:body + lace]
            body += lace
            if lace < 255:
                packets.append(partial)
                partial = b""
        i = body
    return [p for p in packets if not p.startswith((b"OpusHead", b"OpusTags"))]


def check_microphone(phone, status):
    source = node(status, "check-microphone", "caboose_phone_microphone")
    env = dict(os.environ)
    for line in open(DISPLAY_ENV):
        if line.startswith("PULSE_SERVER="):
            env["PULSE_SERVER"] = line.split("=", 1)[1].strip().strip("'\"")
    recording = tempfile.TemporaryFile()
    recorder = subprocess.Popen(["parec", f"--device={source}", "--raw", "--format=s16le", "--rate=48000",
                                 "--channels=1", "--latency-msec=20"], stdout=recording, env=env)
    try:
        phone.device_message("device.open", "check-microphone", 5)
        start = time.monotonic()
        for n, packet in enumerate(opus_packets(1.5, 1000)):
            phone.send("device.audio", {"device": "check-microphone", "t_us": int(time.monotonic() * 1e6), "data": packet})
            time.sleep(max(0, start + (n + 1) * 0.02 - time.monotonic()))
        time.sleep(0.3)
    finally:
        recorder.terminate()
        try:
            recorder.wait(timeout=3)
        except subprocess.TimeoutExpired:
            recorder.kill()
            recorder.wait(timeout=3)
        recording.seek(0)
        pcm = array.array("h", recording.read())
        recording.close()
    phone.device_message("device.close", "check-microphone", 5)
    loudest = max((abs(s) for s in pcm), default=0)
    if loudest < 4000:
        raise Failed(f"recorded {len(pcm)} samples, loudest {loudest}: the tone did not arrive")


def check_disconnect(phone, status):
    gamepad = node(status, "check-gamepad", "/dev/input/event")
    phone.close()
    deadline = time.monotonic() + 3
    while time.monotonic() < deadline and os.path.exists(gamepad):
        time.sleep(0.1)
    if os.path.exists(gamepad):
        raise Failed(f"{gamepad} remained after the phone left")
    leftovers = [p for p in glob.glob("/sys/class/power_supply/hid-caboose-check-*")]
    if leftovers:
        raise Failed(f"left behind: {leftovers}")


CHECKS = [("gamepad", check_gamepad), ("buttons", check_buttons), ("motion", check_motion), ("iio", check_iio),
          ("battery", check_battery), ("camera", check_camera), ("depth", check_depth),
          ("microphone", check_microphone), ("disconnect", check_disconnect)]


def main():
    global DISPLAY_ENV
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--expect-no-devices", action="store_true", help="verify an agent seat rejects devices")
    parser.add_argument("--token-file", default=TOKEN)
    parser.add_argument("--display-env", default=DISPLAY_ENV)
    parser.add_argument("--port", type=int, default=14600)
    parser.add_argument("--only", default="")
    parser.add_argument("--allow-unavailable", default="", help="kinds whose unavailability is not a failure")
    args = parser.parse_args()
    only = set(filter(None, args.only.split(",")))
    allowed = set(filter(None, args.allow_unavailable.split(",")))
    known = {name for name, _ in CHECKS}
    unknown = (only | allowed) - known
    if unknown:
        parser.error(f"unknown checks: {', '.join(sorted(unknown))}")
    if os.geteuid() != 0:
        sys.exit("run as root: the check enables IIO buffers and reads the token")
    DISPLAY_ENV = args.display_env
    phone = Phone(args.port, args.token_file, not args.expect_no_devices)
    try:
        phone.send("devices", {"devices": DEVICES})
        if args.expect_no_devices:
            try:
                phone.wait(lambda m: m[0].startswith("device."), 2)
            except Failed:
                print("PASS no-devices: capability absent and offers ignored")
                return
            raise Failed("agent seat responded to a device offer")
        status = status_of(phone)
        failures = 0
        for name, check in CHECKS:
            if only and name not in only:
                continue
            try:
                check(phone, status)
                print(f"PASS {name}")
            except Unavailable as e:
                print(f"{'SKIP' if name in allowed else 'FAIL'} {name}: unavailable: {e}")
                failures += name not in allowed
            except (Failed, OSError, subprocess.SubprocessError) as e:
                print(f"FAIL {name}: {e}")
                failures += 1
    finally:
        phone.close()
    sys.exit(1 if failures else 0)


if __name__ == "__main__":
    main()
