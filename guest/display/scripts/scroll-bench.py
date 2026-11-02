#!/usr/bin/python3 -I
"""Wheel-scroll a window through the control socket and report what it cost.

usage: scroll-bench.py [--control SOCK] [--window ID | --largest] [--clicks N] [--interval S]

Scrolls the window (by default the largest toplevel) up and down by N wheel clicks, one
every S seconds, and prints JSON: the window's commits and presented pictures per second,
the compositor's renders, milliseconds per render, upload bytes per present and presents
per second, from the control socket's `stats` and `frames` before and after. Run it as the
display's user while a phone is attached and shows the window."""
import argparse
import json
import socket
import time

DEFAULT = "/run/user/1000/caboose-display/wayland-caboose-0/control.sock"


class Control:
    def __init__(self, path):
        sock = socket.socket(socket.AF_UNIX)
        sock.connect(path)
        self.file = sock.makefile("rwb")

    def ask(self, command):
        self.file.write((command + "\n").encode())
        self.file.flush()
        answer = json.loads(self.file.readline())
        if not answer.get("ok"):
            raise SystemExit(f"{command}: {answer.get('error')}")
        return answer


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--control", default=DEFAULT)
    parser.add_argument("--window", type=int)
    parser.add_argument("--clicks", type=int, default=60)
    parser.add_argument("--interval", type=float, default=0.05)
    args = parser.parse_args()
    control = Control(args.control)
    windows = [w for w in control.ask("windows")["windows"] if w["kind"] != "popup"]
    if args.window is not None:
        window = next(w for w in windows if w["id"] == args.window)
    else:
        window = max(windows, key=lambda w: w["rect"][2] * w["rect"][3])
    x, y, width, height = window["rect"]
    before = control.ask("stats")
    since = control.ask("frames")["now_us"]
    start = time.monotonic()
    for i in range(args.clicks):
        control.ask(f"scroll {x + width // 2} {y + height // 2} 0 {1 if (i // 20) % 2 == 0 else -1}")
        time.sleep(args.interval)
    seconds = time.monotonic() - start
    time.sleep(1)
    after = control.ask("stats")
    frames = control.ask(f"frames {since}")
    own = next((w for w in frames.get("windows", []) if w.get("id") == window["id"]), {})
    delta = {key: after[key] - before[key] for key in ("renders", "render_us", "uploaded_bytes", "presents", "unshown")}
    print(json.dumps({
        "window": window["id"], "app_id": window.get("app_id"), "rect": window["rect"], "seconds": round(seconds, 2),
        "renderer": after.get("renderer"),
        "commits_per_s": round(len(own.get("commits", [])) / seconds, 1),
        "pictures_per_s": round(len(own.get("presents", [])) / seconds, 1),
        "renders": delta["renders"],
        "ms_per_render": round(delta["render_us"] / max(1, delta["renders"]) / 1000, 1),
        "upload_mb_per_present": round(delta["uploaded_bytes"] / max(1, delta["presents"]) / 1e6, 2),
        "presents_per_s": round(delta["presents"] / seconds, 1),
        "direct_presents": after.get("direct_presents", 0) - before.get("direct_presents", 0),
        "unshown": delta["unshown"],
    }))


if __name__ == "__main__":
    main()
