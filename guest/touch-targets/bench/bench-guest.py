#!/usr/bin/env python3
"""The guest side of the touch-targeting benchmark (README.md): runs each test app on a
Caboose Display seat, records the toolkit's own layout (the truth) and what
caboose-targets.py reads from the accessibility tree, and optionally replays taps through
the seat's pointer and records which control each one reached.

    bench-guest.py --env display.env --out DIR [--apps a,b] [--clicks clicks.json]

Writes DIR/<app>.json: {"app", "window": [x, y, w, h], "truth": [...], "provided": [...],
"timings": {...}, "presses": [...]?}. All rectangles are window-local logical pixels.
`clicks.json` is {"<app>": [{"at": [x, y], "want": NAME}, ...]}, window-local.
"""

import argparse
import http.server
import json
import os
import shlex
import subprocess
import sys
import tempfile
import threading
import time

HERE = os.path.dirname(os.path.abspath(__file__))
DEBUG_MENU = False

APPS = {
    "gtk3-x11": {"kind": "gtk", "env": {"GDK_BACKEND": "x11"}},
    "gtk3-wayland": {"kind": "gtk", "env": {"GDK_BACKEND": "wayland"}},
    "chromium-x11": {"kind": "web", "ozone": "x11"},
    "chromium-wayland": {"kind": "web", "ozone": "wayland"},
}


def load_env(path):
    with open(path, encoding="utf-8") as handle:
        for line in handle:
            line = line.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            key, value = line.split("=", 1)
            parts = shlex.split(value) if value else [""]
            os.environ[key] = parts[0] if parts else ""


class Reports:
    """What the web page posts: its truth, then its presses."""

    def __init__(self):
        self.lock = threading.Lock()
        self.items = []

    def add(self, item):
        with self.lock:
            self.items.append(item)

    def take(self):
        with self.lock:
            items, self.items = self.items, []
        return items


def serve(reports):
    class Handler(http.server.SimpleHTTPRequestHandler):
        def __init__(self, *args, **kwargs):
            super().__init__(*args, directory=HERE, **kwargs)

        def do_POST(self):
            length = int(self.headers.get("Content-Length") or 0)
            try:
                reports.add(json.loads(self.rfile.read(length)))
            except ValueError:
                pass
            self.send_response(204)
            self.end_headers()

        def log_message(self, *_):
            pass

    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    return server.server_address[1]


class App:
    def __init__(self, name, config, port, scratch, reports):
        self.name = name
        self.config = config
        self.reports = reports
        self.read_to = 0
        env = dict(os.environ, **config.get("env", {}))
        if config["kind"] == "gtk":
            command = [sys.executable, os.path.join(HERE, "gtk3-targets.py")]
            self.out = open(os.path.join(scratch, f"{name}.out"), "w+", encoding="utf-8")
            self.process = subprocess.Popen(command, env=env, stdout=self.out, stderr=subprocess.DEVNULL,
                                            start_new_session=True)
        else:
            profile = tempfile.mkdtemp(dir=scratch, prefix="chromium-")
            command = ["chromium", f"--app=http://127.0.0.1:{port}/targets.html", f"--ozone-platform={config['ozone']}",
                       "--force-renderer-accessibility", "--no-first-run", "--no-default-browser-check",
                       "--disable-gpu", f"--user-data-dir={profile}", "--window-size=1000,700",
                       "--window-position=0,0", "--password-store=basic"]
            self.out = None
            self.process = subprocess.Popen(command, env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                                            start_new_session=True)

    def lines(self):
        if self.reports is not None:
            return self.reports.take()
        self.out.seek(self.read_to)
        text = self.out.read()
        # Only whole lines; a partial one is read again next time.
        text = text[:text.rfind("\n") + 1]
        self.read_to += len(text.encode())
        found = []
        for line in text.splitlines():
            try:
                found.append(json.loads(line))
            except ValueError:
                pass
        return found

    def stop(self):
        try:
            os.killpg(self.process.pid, 15)
        except ProcessLookupError:
            pass
        try:
            self.process.wait(5)
        except subprocess.TimeoutExpired:
            os.killpg(self.process.pid, 9)


def find_window(seat, pid, title, timeout=30):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        for window in seat.windows().get("windows", []):
            if window["kind"] != "popup" and (window.get("pid") == pid or title in (window.get("title") or "")):
                return window
        time.sleep(0.2)
    return None


def targets_lines(path):
    try:
        with open(path, encoding="utf-8") as handle:
            return [json.loads(line) for line in handle if line.strip()]
    except (OSError, ValueError):
        return []


def update_latency(seat, window, truth, path, rounds=6):
    """How long after a click the client has the window's new targets: the test app's
    More button shows and hides a row of buttons, and each click is timed to the
    compositor's next `targets` for the window."""
    more = next((t for t in truth if t["name"] == "more"), None)
    if more is None or not path:
        return None
    wx, wy = window["rect"][0], window["rect"][1]
    x, y, w, h = more["rect"]
    found = []
    for _ in range(rounds):
        before = len(targets_lines(path))
        clicked = time.monotonic()
        seat.click(wx + x + w / 2, wy + y + h / 2)
        deadline = clicked + 3
        got = None
        while time.monotonic() < deadline and got is None:
            fresh = [l for l in targets_lines(path)[before:] if l["id"] == window["id"]]
            if fresh:
                got = round(fresh[0]["t_us"] / 1000 - clicked * 1000, 1)
            time.sleep(0.005)
        found.append(got)
        time.sleep(0.8)
    return found


def run_app(name, config, port, reports, scratch, clicks, repeat, targets_log=None):
    from seat import Seat, SeatError
    import importlib.util
    spec = importlib.util.spec_from_file_location("caboose_targets", os.path.join(os.path.dirname(HERE), "..", "desktop-mcp", "caboose-targets.py"))
    targets = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(targets)

    seat = Seat()
    app = App(name, config, port, scratch, reports)
    result = {"app": name}
    try:
        title = "Caboose targets"
        window = find_window(seat, app.process.pid, title)
        if window is None:
            result["error"] = "no window"
            return result
        seat.focus(window["id"])
        truth = None
        deadline = time.monotonic() + 30
        seen = []
        while truth is None and time.monotonic() < deadline:
            for item in app.lines():
                seen.append(item)
                if "truth" in item:
                    truth = item
            time.sleep(0.2)
        if truth is None:
            result["error"] = "no truth"
            return result
        time.sleep(0.5)
        window = next(w for w in seat.windows()["windows"] if w["id"] == window["id"])
        # GTK lays out its whole surface, client-side shadows included; the window's
        # geometry starts inside them.
        shift = [0, 0]
        if config["kind"] == "gtk":
            shift = [window["rect"][0] - window["surface"][0], window["rect"][1] - window["surface"][1]]
        for item in truth["truth"]:
            item["rect"] = [item["rect"][0] - shift[0], item["rect"][1] - shift[1]] + item["rect"][2:]
        result.update(window=window["rect"], surface=window["surface"], x11=bool(window.get("x11")),
                      truth=truth["truth"], truth_shift=shift, truth_size=truth.get("size"))
        timings = {}
        reader = targets.Reader(os.environ.get("DISPLAY", ""))
        wx, wy = window["rect"][0], window["rect"][1]
        for method in ("walk", "collection"):
            runs = [reader.snapshot(method) for _ in range(repeat)]
            timings[method] = [r.get("ms") for r in runs]
            result[f"provided_{method}"] = [[x - wx, y - wy, w, h, k] for x, y, w, h, k in runs[-1].get("targets", [])]
            result[f"nodes_{method}"] = runs[-1].get("nodes")
            result[f"window_{method}"] = runs[-1].get("window")
        result["provided"] = result["provided_walk"]
        result["timings"] = timings
        if targets_log:
            lines = [l for l in targets_lines(targets_log) if l["id"] == window["id"]]
            result["compositor_targets"] = lines[-1]["targets"] if lines else None
            result["update_ms"] = update_latency(seat, window, truth["truth"], targets_log)
            if DEBUG_MENU:
                menu = next(t for t in truth["truth"] if t["kind"] == "menu")
                seat.click(wx + menu["rect"][0] + 5, wy + menu["rect"][1] + 5)
                time.sleep(1.0)
                result["debug"] = {"windows": seat.windows(), "snapshot": reader.snapshot("collection"),
                                   "log": targets_lines(targets_log)[-3:]}
                seat.key("Escape")
        if clicks and name in clicks:
            presses = []
            wx, wy = window["rect"][0], window["rect"][1]
            app.lines()
            for click in clicks[name]:
                x, y = click["at"]
                try:
                    seat.click(wx + x, wy + y)
                except SeatError:
                    presses.append({"want": click["want"], "at": click["at"], "got": None, "tag": click.get("tag")})
                    continue
                time.sleep(0.06)
                got = [item for item in app.lines() if "press" in item]
                seen = got[0].get("at") if got else None
                if seen:
                    seen = [seen[0] - shift[0], seen[1] - shift[1]]
                presses.append({"want": click["want"], "at": click["at"], "got": got[0]["press"] if got else None,
                                "seen_at": seen, "tag": click.get("tag")})
                seat.key("Escape")
                time.sleep(0.03)
                app.lines()
            result["presses"] = presses
        return result
    finally:
        app.stop()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--env", required=True)
    parser.add_argument("--out", required=True)
    parser.add_argument("--apps", default=",".join(APPS))
    parser.add_argument("--clicks")
    parser.add_argument("--repeat", type=int, default=3)
    parser.add_argument("--targets-log", help="the probe's --targets file, to time the compositor's updates")
    parser.add_argument("--debug-menu", action="store_true", help="record the seat and a reading with the first menu open")
    args = parser.parse_args()
    global DEBUG_MENU
    DEBUG_MENU = args.debug_menu
    load_env(args.env)
    sys.path.insert(0, "/opt/caboose")
    os.makedirs(args.out, exist_ok=True)
    clicks = json.load(open(args.clicks, encoding="utf-8")) if args.clicks else None
    reports = Reports()
    port = serve(reports)
    scratch = tempfile.mkdtemp(prefix="caboose-targets-")
    for name in args.apps.split(","):
        config = APPS[name]
        reports.take()
        started = time.monotonic()
        result = run_app(name, config, port, reports if config["kind"] == "web" else None, scratch, clicks,
                         args.repeat, args.targets_log)
        result["elapsed_s"] = round(time.monotonic() - started, 1)
        with open(os.path.join(args.out, f"{name}.json"), "w", encoding="utf-8") as handle:
            json.dump(result, handle)
        summary = {k: result.get(k) for k in ("app", "error", "window", "timings", "update_ms", "elapsed_s")}
        summary["compositor_targets"] = len(result.get("compositor_targets") or [])
        summary["truth"] = len(result.get("truth") or [])
        summary["provided"] = len(result.get("provided") or [])
        if "presses" in result:
            summary["e2e_hits"] = sum(p["got"] == p["want"] for p in result["presses"])
            summary["e2e_total"] = len(result["presses"])
        print(json.dumps(summary), flush=True)


if __name__ == "__main__":
    main()
