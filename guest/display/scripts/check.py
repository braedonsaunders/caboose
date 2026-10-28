#!/usr/bin/env python3
"""Scripted checks for caboose-display against real applications.

Runs in the dev container (guest/display/Dockerfile), or on any Linux host with the
binaries built and weston, xterm, Chromium and Xwayland installed:

    guest/display/scripts/dev.sh python3 scripts/check.py           # everything
    guest/display/scripts/dev.sh python3 scripts/check.py chromium  # by name

Each scenario starts the compositor with an application, connects the headless probe
(which decodes every frame with libavcodec and acknowledges it), asserts on what
arrived, and prints fps, latency and the server's CPU time per frame.
"""
import json
import os
import shutil
import subprocess
import sys
import tempfile
import time

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
BIN = os.environ.get("CABOOSE_DISPLAY_BIN", os.path.join(ROOT, "target", "debug"))
PORT = 14600
CHROMIUM = ["chromium", "--ozone-platform=wayland", "--no-sandbox", "--disable-gpu", "--no-first-run",
            "--disable-features=Translate", "--user-data-dir=/tmp/caboose-check-chromium"]
PAGES = "file://" + os.path.join(HERE, "pages")


class Failed(Exception):
    pass


def compositor(command, token_file, extra=()):
    env = dict(os.environ)
    env.setdefault("XDG_RUNTIME_DIR", tempfile.mkdtemp(prefix="xdg-"))
    os.chmod(env["XDG_RUNTIME_DIR"], 0o700)
    log = open(os.path.join(env["XDG_RUNTIME_DIR"], "caboose-display.log"), "w")
    proc = subprocess.Popen(
        [os.path.join(BIN, "caboose-display"), "--listen", f"127.0.0.1:{PORT}", "--token-file", token_file, *extra, "--", *command],
        env=env, stdout=log, stderr=subprocess.STDOUT)
    for _ in range(100):
        if probe(["--check", "--token-file", token_file], check=False, json_out=False).returncode == 0:
            return proc
        if proc.poll() is not None:
            raise Failed(f"compositor exited: {proc.returncode}")
        time.sleep(0.1)
    proc.kill()
    raise Failed("compositor did not answer hello")


def probe(args, check=True, json_out=True, timeout=120):
    cmd = [os.path.join(BIN, "caboose-display-probe"), "--url", f"ws://127.0.0.1:{PORT}/", *args]
    if json_out:
        cmd.append("--json")
    r = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
    if not json_out:
        return r
    try:
        report = json.loads(r.stdout.strip().splitlines()[-1])
    except (IndexError, json.JSONDecodeError):
        raise Failed(f"probe gave no report: {r.stdout} {r.stderr}")
    if check and not report["ok"]:
        raise Failed(f"probe failed: {r.stdout.strip()} {r.stderr.strip()}")
    return report


def stop(proc):
    proc.terminate()
    try:
        proc.wait(timeout=10)
    except subprocess.TimeoutExpired:
        proc.kill()


def wait_for_file(path, seconds=10):
    for _ in range(seconds * 10):
        if os.path.exists(path) and os.path.getsize(path) > 0:
            return open(path, encoding="utf-8").read().rstrip("\n")
        time.sleep(0.1)
    raise Failed(f"{path} was never written")


def summary(report):
    w = max(report["windows"], key=lambda w: w["frames"])
    cpu = report["server_cpu_ms_per_frame"]
    return (f'{w["codec"]} {w["size"][0]}x{w["size"][1]} {w["fps"]:.1f} fps, latency p50 {w["latency_ms_p50"]:.1f} ms '
            f'p95 {w["latency_ms_p95"]:.1f} ms, server {report["server_cpu_pct"]}% of a core'
            + (f", {cpu} ms CPU/frame" if cpu else ""))


def with_server(command, fn, extra=()):
    token = tempfile.NamedTemporaryFile("w", delete=False, prefix="token-")
    token.write("check-token\n")
    token.close()
    proc = compositor(command, token.name, extra)
    try:
        time.sleep(2)  # let the application map its first window
        return fn(proc, token.name)
    finally:
        stop(proc)
        os.unlink(token.name)


def check_auth():
    def run(proc, token):
        bad = probe(["--token", "wrong", "--duration", "2"], check=False)
        if bad["ok"]:
            raise Failed("a wrong token was accepted")
        good = probe(["--token-file", token, "--duration", "2", "--windows", "1"])
        return f'wrong token refused, right token accepted ({len(good["windows"])} window)'
    return with_server(["weston-terminal"], run)


def check_wayland_terminal():
    typed = os.path.join(tempfile.mkdtemp(), "typed")
    os.environ["CABOOSE_TYPED"] = typed
    text = "echo $((6*7)) ~!@#%^&*()_+{}|:<>? caboose"
    def run(proc, token):
        r = probe(["--token-file", token, "--duration", "3", "--windows", "1", "--type", text + "\n"])
        got = wait_for_file(typed)
        if got != text:
            raise Failed(f"typed {text!r}, terminal read {got!r}")
        return "typed text arrives exactly (key fallback, no text-input-v3); " + summary(r)
    return with_server(["weston-terminal", f"--shell={HERE}/read-line.sh"], run)


def check_x11_terminal():
    typed = os.path.join(tempfile.mkdtemp(), "typed")
    text = "X11 says $HOME ~!@#%^&*()_+{}|:<>? ok"
    def run(proc, token):
        r = probe(["--token-file", token, "--duration", "3", "--windows", "1", "--type", text + "\n"])
        got = wait_for_file(typed)
        if got != text:
            raise Failed(f"typed {text!r}, xterm read {got!r}")
        return "Xwayland window, typed text arrives exactly; " + summary(r)
    env_cmd = ["env", f"CABOOSE_TYPED={typed}", "xterm", "-e", f"{HERE}/read-line.sh"]
    return with_server(env_cmd, run)


def check_shm_animation():
    def run(proc, token):
        r = probe(["--token-file", token, "--duration", "6", "--windows", "1", "--min-fps", "55",
                   "--server-pid", str(proc.pid)])
        return "paced on vsync; " + summary(r)
    return with_server(["weston-simple-shm"], run)


def check_hevc():
    def run(proc, token):
        r = probe(["--token-file", token, "--duration", "4", "--windows", "1", "--decoders", "hevc",
                   "--server-pid", str(proc.pid)])
        if r["windows"][0]["codec"] != "hevc":
            raise Failed(f'got {r["windows"][0]["codec"]}')
        return "a client that decodes only HEVC gets x265; " + summary(r)
    return with_server(["weston-simple-shm"], run)


def check_two_windows():
    def run(proc, token):
        r = probe(["--token-file", token, "--duration", "3", "--windows", "2"])
        return f'{len(r["windows"])} windows streamed independently'
    return with_server(["sh", "-c", "weston-terminal & exec weston-simple-shm"], run)


def check_chromium_motion():
    def run(proc, token):
        time.sleep(4)
        r = probe(["--token-file", token, "--duration", "8", "--windows", "1", "--min-fps", "55",
                   "--display", "1280x800@60x1", "--server-pid", str(proc.pid)])
        return "Chromium (Wayland, software raster) 60 Hz animation; " + summary(r)
    return with_server(CHROMIUM + ["--window-size=1280,720", f"--app={PAGES}/motion.html"], run)


def check_chromium_text_input():
    text = "héllo wörld ✓"
    def run(proc, token):
        time.sleep(4)
        r = probe(["--token-file", token, "--duration", "4", "--windows", "1", "--touch", "400,250", "--type", text])
        title = r["windows"][0]["title"]
        if r["text_input_events"] < 1:
            raise Failed("no text_input message: text-input-v3 was not enabled")
        if title != f"touch|{text}":
            raise Failed(f"page saw {title!r}")
        return "touch reached the page; text-input-v3 enabled and committed exactly"
    return with_server(CHROMIUM + ["--enable-wayland-ime", "--wayland-text-input-version=3", "--window-size=900,400",
                                   f"--app={PAGES}/input.html"], run)


def check_reconnect():
    def run(proc, token):
        a = probe(["--token-file", token, "--duration", "2", "--windows", "1"])
        b = probe(["--token-file", token, "--duration", "2", "--windows", "1"])
        ids = lambda r: sorted(w["id"] for w in r["windows"])
        if ids(a) != ids(b):
            raise Failed(f"window ids changed across reconnect: {ids(a)} → {ids(b)}")
        if not all(w["keyframe_first"] for w in b["windows"]):
            raise Failed("a reconnecting client did not start with a keyframe")
        return f"same window ids {ids(b)} after reconnect, each starting with a keyframe"
    return with_server(["weston-simple-shm"], run)


def check_replace():
    def run(proc, token):
        first = subprocess.Popen(
            [os.path.join(BIN, "caboose-display-probe"), "--url", f"ws://127.0.0.1:{PORT}/", "--token-file", token,
             "--duration", "6", "--json"], stdout=subprocess.PIPE, text=True)
        time.sleep(2)
        probe(["--token-file", token, "--duration", "2", "--windows", "1"])
        out, _ = first.communicate(timeout=30)
        report = json.loads(out.strip().splitlines()[-1])
        if report["bye"] != "shutdown":
            raise Failed(f"the replaced client got bye {report['bye']!r}")
        return "a second client takes over; the first gets bye(shutdown)"
    return with_server(["weston-simple-shm"], run)


def check_popup():
    def run(proc, token):
        time.sleep(4)
        r = probe(["--token-file", token, "--duration", "4", "--windows", "2", "--click", "200,115",
                   "--display", "1280x800@60x1"])
        popups = [w for w in r["windows"] if w["kind"] == "popup"]
        main = [w for w in r["windows"] if w["kind"] == "toplevel"]
        if not popups or not main or popups[0]["parent"] != main[0]["id"]:
            raise Failed(f"expected a popup parented to the page: {r['windows']}")
        g = popups[0]["geometry"]
        if popups[0]["frames"] < 1:
            raise Failed("the popup was never streamed")
        return f"<select> list is its own popup window, parent {main[0]['id']}, at {g} relative to it"
    return with_server(CHROMIUM + ["--window-size=900,400", f"--app={PAGES}/popup.html"], run)


def check_idle():
    def run(proc, token):
        r = probe(["--token-file", token, "--duration", "10", "--windows", "1", "--server-pid", str(proc.pid)])
        pct = r["server_cpu_pct"]
        if pct is None or pct > 2.0:
            raise Failed(f"idle window cost {pct}% of a core")
        return f"idle window with a client ticking vsync at 60 Hz: {pct}% of a core"
    return with_server(["weston-terminal"], run)


CHECKS = [
    ("auth", check_auth),
    ("wayland-terminal", check_wayland_terminal),
    ("x11-terminal", check_x11_terminal),
    ("shm-animation", check_shm_animation),
    ("hevc", check_hevc),
    ("two-windows", check_two_windows),
    ("chromium", check_chromium_motion),
    ("chromium-text-input", check_chromium_text_input),
    ("reconnect", check_reconnect),
    ("replace", check_replace),
    ("popup", check_popup),
    ("idle", check_idle),
]


def main():
    wanted = sys.argv[1:]
    missing = [b for b in ("weston-terminal", "weston-simple-shm", "xterm", "chromium", "Xwayland") if not shutil.which(b)]
    if missing:
        print(f"missing: {', '.join(missing)}", file=sys.stderr)
        return 2
    failures = 0
    for name, fn in CHECKS:
        if wanted and not any(w in name for w in wanted):
            continue
        started = time.time()
        try:
            detail = fn()
            print(f"PASS {name}: {detail} [{time.time() - started:.0f}s]", flush=True)
        except Exception as e:  # noqa: BLE001 - every failure is reported, then the next check runs
            failures += 1
            print(f"FAIL {name}: {e}", flush=True)
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
