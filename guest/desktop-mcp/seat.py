#!/usr/bin/env python3
"""A Caboose Display seat through its control socket (guest/display, control.rs).

Lists the seat's windows, Wayland and X11 alike, with each one's process, geometry and
focus; clicks, scrolls, presses keys and types with the seat's own pointer and keyboard;
and takes pictures of a window or the whole seat. The socket is the instance's
CABOOSE_DISPLAY_CONTROL, from the display's launch environment. Positions are in the
compositor's logical space, which X11 clients see as their root window's.

    seat.py windows                         {"windows": [...], "focused", "bounds"}
    seat.py click X Y [--button B] [--count N]
    seat.py drag X1 Y1 X2 Y2
    seat.py scroll X Y DX DY
    seat.py key COMBO...                    xdotool-style: ctrl+s, alt+F4, Return
    seat.py type TEXT
    seat.py focus ID
    seat.py screenshot [--window ID] --out FILE.png

Prints one JSON object; exits 1 with {"error"} when the seat refuses, 2 on bad arguments.
"""

from __future__ import annotations

import argparse
import glob
import json
import os
import socket
import sys
import time

TIMEOUT = 20.0


class SeatError(Exception):
    pass


def control_path():
    return os.environ.get("CABOOSE_DISPLAY_CONTROL") or None


def all_sockets():
    """Every Caboose Display instance's control socket for this user."""
    runtime = os.environ.get("XDG_RUNTIME_DIR") or f"/run/user/{os.getuid()}"
    return sorted(glob.glob(os.path.join(runtime, "caboose-display", "*", "control.sock")))


class Seat:
    def __init__(self, path=None):
        self.conn = None
        self.path = path or control_path()
        if not self.path:
            raise SeatError("CABOOSE_DISPLAY_CONTROL is not set: no Caboose Display seat to talk to")

    def close(self):
        if self.conn is not None:
            self.conn.close()
            self.conn = None

    def __del__(self):
        self.close()

    def request(self, line):
        """One request: the JSON answer, and the bytes that follow it (a picture), if any."""
        if "\n" in line:
            raise SeatError("a request is one line")
        try:
            if self.conn is None:
                self.conn = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
                self.conn.settimeout(TIMEOUT)
                self.conn.connect(self.path)
            conn = self.conn
            conn.sendall(line.encode() + b"\n")
            data = b""
            while b"\n" not in data:
                chunk = conn.recv(65536)
                if not chunk:
                    raise SeatError("the seat closed the connection")
                data += chunk
            head, _, rest = data.partition(b"\n")
            answer = json.loads(head)
            if not answer.get("ok"):
                raise SeatError(answer.get("error") or "the seat refused")
            payload = None
            if isinstance(answer.get("png"), int):
                need = answer["png"]
                chunks = [rest]
                have = len(rest)
                while have < need:
                    chunk = conn.recv(min(1 << 20, need - have))
                    if not chunk:
                        raise SeatError("the picture was cut short")
                    chunks.append(chunk)
                    have += len(chunk)
                payload = b"".join(chunks)[:need]
            return answer, payload
        except OSError as error:
            self.close()
            raise SeatError(f"cannot reach the seat at {self.path}: {error}") from None
        except (SeatError, ValueError):
            self.close()
            raise

    def windows(self):
        return self.request("windows")[0]

    def focus(self, window):
        self.request(f"focus {int(window)}")

    def click(self, x, y, button="left", count=1):
        return self.request(f"click {x:.2f} {y:.2f} {button} {int(count)}")[0]

    def drag(self, x1, y1, x2, y2, button="left", steps=8):
        self.request(f"press {x1:.2f} {y1:.2f} {button}")
        for i in range(1, steps + 1):
            t = i / steps
            self.request(f"move {x1 + (x2 - x1) * t:.2f} {y1 + (y2 - y1) * t:.2f}")
            time.sleep(0.01)
        self.request(f"release {x2:.2f} {y2:.2f} {button}")

    def scroll(self, x, y, dx, dy):
        self.request(f"scroll {x:.2f} {y:.2f} {dx:g} {dy:g}")

    def key(self, *combos):
        if not combos:
            raise SeatError("no key combo")
        self.request("key " + " ".join(combos))

    def type(self, text):
        if text:
            self.request("type " + text.replace("\\", "\\\\").replace("\n", "\\n").replace("\t", "\\t"))

    def settle(self, rounds=3, pause=0.05):
        """Let applications draw what they have: a seat nobody watches paces them at once a
        second, so a picture taken right after an action could show the moment before it."""
        for _ in range(rounds):
            answer, _ = self.request("settle")
            if answer.get("released") == 0:
                break
            time.sleep(pause)

    def screenshot(self, window=None):
        self.settle()
        answer, png = self.request("screenshot" + (f" {int(window)}" if window is not None else ""))
        return answer, png


def pids_on_other_seats(own_path):
    """Processes with a window on any other Caboose Display instance of this user."""
    pids = set()
    own = os.path.realpath(own_path) if own_path else None
    for path in all_sockets():
        if own and os.path.realpath(path) == own:
            continue
        try:
            for window in Seat(path).windows()["windows"]:
                if window.get("pid"):
                    pids.add(window["pid"])
        except (SeatError, ValueError, KeyError):
            continue
    return pids


class Parser(argparse.ArgumentParser):
    def error(self, message):
        print(json.dumps({"error": message}))
        sys.exit(2)


def serve():
    seat = Seat()
    try:
        for line in sys.stdin:
            try:
                args = json.loads(line)["args"]
                op = args[0]
                if op == "annotate":
                    from annotate import annotate
                    print(json.dumps({"legend": annotate(*args[1:])}), flush=True)
                    continue
                if op == "windows":
                    result = seat.windows()
                    result.pop("ok", None)
                elif op == "settle":
                    seat.settle()
                    result = {"ok": True}
                elif op == "screenshot":
                    window = int(args[args.index("--window") + 1]) if "--window" in args else None
                    answer, png = seat.screenshot(window)
                    with open(args[args.index("--out") + 1], "wb") as handle:
                        handle.write(png)
                    result = answer
                elif op == "click":
                    result = seat.click(float(args[1]), float(args[2]), args[4], int(args[6]))
                elif op in ("drag", "scroll"):
                    getattr(seat, op)(*[float(v) for v in args[1:]])
                    result = {"ok": True}
                elif op == "focus":
                    seat.focus(int(args[1]))
                    result = {"ok": True}
                elif op in ("key", "type"):
                    getattr(seat, op)(*args[2:])
                    result = {"ok": True}
                else:
                    raise SeatError("unknown worker operation")
            except Exception as error:
                result = {"error": str(error)}
            print(json.dumps(result), flush=True)
    finally:
        seat.close()


def main(argv):
    parser = Parser(prog="seat.py", description="Act on a Caboose Display seat through its control socket.")
    commands = parser.add_subparsers(dest="command", required=True, parser_class=Parser)
    commands.add_parser("windows")
    click = commands.add_parser("click")
    click.add_argument("x", type=float)
    click.add_argument("y", type=float)
    click.add_argument("--button", default="left", choices=["left", "middle", "right"])
    click.add_argument("--count", type=int, default=1, choices=[1, 2, 3])
    drag = commands.add_parser("drag")
    for name in ("x1", "y1", "x2", "y2"):
        drag.add_argument(name, type=float)
    scroll = commands.add_parser("scroll")
    for name in ("x", "y", "dx", "dy"):
        scroll.add_argument(name, type=float)
    key = commands.add_parser("key")
    key.add_argument("combos", nargs="+")
    typed = commands.add_parser("type")
    typed.add_argument("text")
    focus = commands.add_parser("focus")
    focus.add_argument("window", type=int)
    shot = commands.add_parser("screenshot")
    shot.add_argument("--window", type=int)
    shot.add_argument("--out", required=True)
    args = parser.parse_args(argv)
    try:
        seat = Seat()
        if args.command == "windows":
            result = seat.windows()
            result.pop("ok", None)
        elif args.command == "click":
            result = {"ok": True, "window": seat.click(args.x, args.y, args.button, args.count).get("window")}
        elif args.command == "drag":
            seat.drag(args.x1, args.y1, args.x2, args.y2)
            result = {"ok": True}
        elif args.command == "scroll":
            seat.scroll(args.x, args.y, args.dx, args.dy)
            result = {"ok": True}
        elif args.command == "key":
            seat.key(*args.combos)
            result = {"ok": True}
        elif args.command == "type":
            seat.type(args.text)
            result = {"ok": True}
        elif args.command == "focus":
            seat.focus(args.window)
            result = {"ok": True}
        else:
            answer, png = seat.screenshot(args.window)
            with open(args.out, "wb") as handle:
                handle.write(png or b"")
            result = {"ok": True, "rect": answer.get("rect"), "bytes": len(png or b"")}
    except SeatError as error:
        print(json.dumps({"error": str(error)}))
        sys.exit(1)
    print(json.dumps(result))


if __name__ == "__main__":
    if sys.argv[1:] == ["serve"]:
        serve()
    else:
        main(sys.argv[1:])
