"""seat.py against a stand-in control socket: requests, escapes, refusals and pictures.

    python3 -m unittest guest/desktop-mcp/test_seat.py
"""

import json
import os
import socket
import sys
import tempfile
import threading
import unittest
from unittest.mock import patch

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import seat  # noqa: E402

PNG = b"\x89PNG\r\n\x1a\n" + bytes(range(256)) * 40


class StandIn:
    """Answers each request line as the compositor would, and records it."""

    def __init__(self, path):
        self.lines = []
        self.server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.server.bind(path)
        self.server.listen()
        threading.Thread(target=self.serve, daemon=True).start()

    def serve(self):
        while True:
            try:
                conn, _ = self.server.accept()
            except OSError:
                return
            with conn:
                while True:
                    data = b""
                    while not data.endswith(b"\n"):
                        chunk = conn.recv(4096)
                        if not chunk:
                            break
                        data += chunk
                    if not data:
                        break
                    line = data.decode().rstrip("\n")
                    self.lines.append(line)
                    op = line.split(" ", 1)[0]
                    if op == "windows":
                        conn.sendall(json.dumps({"ok": True, "windows": [{"id": 7, "pid": 42}], "focused": 7}).encode() + b"\n")
                    elif op == "screenshot":
                        conn.sendall(json.dumps({"ok": True, "png": len(PNG), "rect": [0, 0, 10, 10]}).encode() + b"\n")
                        for start in range(0, len(PNG), 1000):  # a picture arrives in pieces
                            conn.sendall(PNG[start:start + 1000])
                    elif op == "focus" and line.endswith(" 99"):
                        conn.sendall(b'{"ok":false,"error":"no such window"}\n')
                    else:
                        conn.sendall(b'{"ok":true}\n')
    def close(self):
        self.server.close()


class SeatTest(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.TemporaryDirectory(dir="/tmp")
        self.path = os.path.join(self.dir.name, "control.sock")
        self.stand_in = StandIn(self.path)
        self.seat = seat.Seat(self.path)

    def tearDown(self):
        self.seat.close()
        self.stand_in.close()
        self.dir.cleanup()

    def test_requests_are_single_lines_with_escaped_text(self):
        self.seat.type("one\ntwo\\three\tfour")
        self.seat.key("ctrl+a", "BackSpace")
        self.seat.click(10.5, 20, "right", 2)
        self.assertEqual(self.stand_in.lines, [
            "type one\\ntwo\\\\three\\tfour", "key ctrl+a BackSpace", "click 10.50 20.00 right 2"])

    def test_screenshots_read_the_whole_picture_after_letting_apps_draw(self):
        answer, png = self.seat.screenshot()
        self.assertEqual(png, PNG)
        self.assertEqual(answer["rect"], [0, 0, 10, 10])
        self.assertEqual(self.stand_in.lines, ["settle", "settle", "settle", "screenshot"])

    def test_a_refusal_is_an_error(self):
        with self.assertRaisesRegex(seat.SeatError, "no such window"):
            self.seat.focus(99)

    def test_settle_does_not_sleep_when_nothing_was_released(self):
        with patch.object(self.seat, "request", return_value=({"ok": True, "released": 0}, None)) as request, patch.object(seat.time, "sleep") as sleep:
            self.seat.settle()
            request.assert_called_once_with("settle")
            sleep.assert_not_called()

    def test_reuses_connection_and_recovers_on_next_request(self):
        self.seat.windows()
        conn = self.seat.conn
        self.seat.windows()
        self.assertIs(self.seat.conn, conn)
        self.seat.close()
        self.assertEqual(self.seat.windows()["focused"], 7)
        self.assertIsNot(self.seat.conn, conn)

    def test_windows(self):
        self.assertEqual(self.seat.windows()["focused"], 7)

    def test_without_a_socket(self):
        with self.assertRaisesRegex(seat.SeatError, "cannot reach the seat"):
            seat.Seat(os.path.join(self.dir.name, "missing.sock")).windows()
        os.environ.pop("CABOOSE_DISPLAY_CONTROL", None)
        with self.assertRaisesRegex(seat.SeatError, "CABOOSE_DISPLAY_CONTROL"):
            seat.Seat()

    def test_other_seats_report_their_processes(self):
        runtime = os.path.join(self.dir.name, "runtime")
        other = os.path.join(runtime, "caboose-display", "wayland-caboose-agent")
        os.makedirs(other)
        stand_in = StandIn(os.path.join(other, "control.sock"))
        os.environ["XDG_RUNTIME_DIR"] = runtime
        try:
            self.assertEqual(seat.pids_on_other_seats(self.path), {42})
            self.assertEqual(seat.pids_on_other_seats(os.path.join(other, "control.sock")), set())
        finally:
            stand_in.close()
            os.environ.pop("XDG_RUNTIME_DIR", None)


if __name__ == "__main__":
    unittest.main()
