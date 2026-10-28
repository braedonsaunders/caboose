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


def check_autocorrect():
    # The iOS keyboard's shapes: autocorrect replaces the last character and types on
    # ("caboose" -> "caboose!"), a delete-key press is delete_before without a commit,
    # and one deletion removes one grapheme cluster (an emoji with a skin tone).
    actions = "text:caboose;edit:1:e!;edit:2:;edit:0:d;text: ok 👍🏽;edit:1:;wait:800"
    def run(proc, token):
        time.sleep(4)
        r = probe(["--token-file", token, "--duration", "6", "--windows", "1", "--actions", actions])
        title = r["windows"][0]["title"]
        if title != "none|caboosd ok":
            raise Failed(f"expected 'none|caboosd ok', the page has {title!r}")
        return "commit + delete_before edits apply exactly, a deletion removes one grapheme cluster"
    return with_server(CHROMIUM + ["--enable-wayland-ime", "--wayland-text-input-version=3", "--window-size=900,400",
                                   f"--app={PAGES}/input.html"], run)


def check_text_input_on_connect():
    def run(proc, token):
        time.sleep(4)
        # The page focused its field long before this client: it must still be told.
        for attempt in (1, 2):
            r = probe(["--token-file", token, "--duration", "2", "--windows", "1"])
            if r["text_input_events"] < 1:
                raise Failed(f"connection {attempt} was not told text input is enabled")
        return "each new client is told the focused field has text input enabled"
    return with_server(CHROMIUM + ["--enable-wayland-ime", "--wayland-text-input-version=3", "--window-size=900,400",
                                   f"--app={PAGES}/input.html"], run)


def check_direct_matches_compose():
    # A single-surface shm window is streamed from its buffer; the picture must be the
    # one composition would have made. A static page, streamed both ways, decoded and
    # saved: the PNGs must be identical (x264 on one thread is deterministic).
    pictures = []
    for extra in ((), ("--always-compose",)):
        out = tempfile.mkdtemp(prefix="direct-")
        def run(proc, token, out=out):
            time.sleep(4)
            probe(["--token-file", token, "--duration", "2", "--windows", "1", "--save", out])
            return open(os.path.join(out, "window-1.png"), "rb").read()
        pictures.append(with_server(CHROMIUM + ["--window-size=900,400", f"--app={PAGES}/popup.html"], run, extra=extra))
    if pictures[0] != pictures[1]:
        raise Failed("the directly streamed picture differs from the composed one")
    return f"streaming straight from the shm buffer gives the composed picture exactly ({len(pictures[0])} byte PNG)"


def check_passthrough():
    # A stand-in VA-API driver opens an H.264 stream, streams real access units, and
    # starts Chromium showing the stream's marker at (100, 80) of the page, 640x360.
    # The compositor must find it, bind the stream to Chromium's window there, forward
    # every frame (the probe decodes them) and name presented frames the client has.
    out = tempfile.mkdtemp(prefix="passthrough-")
    def run(proc, token):
        time.sleep(5)
        r = probe(["--token-file", token, "--duration", "6", "--windows", "1", "--video-decoders", "h264",
                   "--display", "1280x800@60x1", "--save", out])
        if len(r["videos"]) != 1:
            raise Failed(f"expected one video stream: {r['videos']}")
        v = r["videos"][0]
        window = r["windows"][0]
        x, y, w, h = v["rect"]
        # The page's infobar (--no-sandbox) pushes content down; the rest is exact.
        if v["window"] != window["id"] or abs(x - 100) > 1 or abs(w - 640) > 1 or abs(h - 360) > 1:
            raise Failed(f"bound at {v['rect']} in window {v['window']}, expected 640x360 at x=100 in {window['id']}")
        if v["frames"] < 100 or v["decode_errors"] or v["decoded"] < v["frames"] - 2:
            raise Failed(f"frames {v['frames']}, decoded {v['decoded']}, errors {v['decode_errors']}")
        if v["presents"] < 30 or v["unknown_presents"]:
            raise Failed(f"presents {v['presents']}, naming unreceived frames {v['unknown_presents']}")
        detail = (f"bound to window {v['window']} at {v['rect']}, {v['frames']} frames decoded by the client, "
                  f"{v['presents']} presents")
        # The driver's reference detector, when its source is mounted, must agree.
        detect = shutil.which("cbva-detect") or ("/tmp/vaapi/cbva-detect" if os.path.exists("/tmp/vaapi/cbva-detect") else None)
        if detect:
            ppm = os.path.join(out, "window-1.ppm")
            subprocess.run(["ffmpeg", "-loglevel", "error", "-y", "-i", os.path.join(out, "window-1.png"), ppm], check=True)
            ref = subprocess.run([detect, ppm], capture_output=True, text=True).stdout
            rect = [float(n) for n in ref.split("rect=")[1].split()[0].split(",")] if "rect=" in ref else None
            if not rect or abs(rect[0] - x) > 1.5 or abs(rect[1] - y) > 1.5 or abs(rect[2] - w) > 2 or abs(rect[3] - h) > 2:
                raise Failed(f"the reference detector disagrees: {ref.strip()!r} vs {v['rect']}")
            detail += "; the driver's reference detector agrees"
        return detail
    return with_server(["python3", f"{HERE}/fake-video-driver.py", "25", *CHROMIUM, "--window-size=900,600"], run)


def check_clipboard_wayland():
    # Phone -> Chromium: the phone's text is pasted with Ctrl+V. Chromium -> phone: typed
    # text is selected and copied with Ctrl+A, Ctrl+C and arrives as a clipboard message.
    actions = "copy:from the phone ✓;key:76+control;wait:600;text: and back;key:61+control;key:63+control;wait:800"
    def run(proc, token):
        time.sleep(4)
        r = probe(["--token-file", token, "--duration", "8", "--windows", "1", "--actions", actions])
        title, clip = r["windows"][0]["title"], r["clipboard"]
        if title != "none|from the phone ✓ and back":
            raise Failed(f"the page has {title!r}: the phone's clipboard did not paste")
        if clip != "from the phone ✓ and back":
            raise Failed(f"the phone got {clip!r} from Chromium's copy")
        return "the phone's text pastes into Chromium, and Chromium's copy reaches the phone"
    return with_server(CHROMIUM + ["--window-size=900,400", f"--app={PAGES}/input.html"], run)


def check_clipboard_x11():
    # X11 -> phone: xclip owns the clipboard before the phone connects; the phone is sent it
    # on hello. Phone -> X11: the phone copies, and xclip reads it back from Xwayland.
    out = os.path.join(tempfile.mkdtemp(), "pasted")
    script = (f"xterm & sleep 2; printf 'from X11' | xclip -i -selection clipboard; "
              f"while sleep 0.3; do t=$(xclip -o -selection clipboard 2>/dev/null); "
              f"[ \"$t\" = 'from the phone' ] && printf %s \"$t\" > {out} && break; done; exec sleep 60")
    def run(proc, token):
        time.sleep(2)
        r = probe(["--token-file", token, "--duration", "3", "--windows", "1", "--actions", "copy:from the phone;wait:500"])
        if r["clipboard"] != "from X11":
            raise Failed(f"the phone got {r['clipboard']!r} from X11's clipboard")
        got = wait_for_file(out)
        return f"X11's clipboard reaches the phone, and the phone's ({got!r}) reaches X11"
    return with_server(["sh", "-c", script], run)


def check_clipboard_bridge():
    # Inside the computer: a Wayland copy pastes into X11, and an X11 copy into Wayland.
    out = os.path.join(tempfile.mkdtemp(), "bridge")
    script = (f"xterm & sleep 2; wl-copy 'from wayland'; sleep 0.5; a=$(xclip -o -selection clipboard); "
              f"printf 'from x11' | xclip -i -selection clipboard; sleep 0.5; b=$(wl-paste --no-newline); "
              f"printf '%s|%s' \"$a\" \"$b\" > {out}; exec sleep 60")
    def run(proc, token):
        got = wait_for_file(out, 15)
        if got != "from wayland|from x11":
            raise Failed(f"X11 read the Wayland copy / Wayland read the X11 copy as {got!r}")
        return "a Wayland copy pastes into X11 and an X11 copy into Wayland"
    return with_server(["sh", "-c", script], run)


def check_audio():
    # A 440 Hz tone played into the session's default output arrives as Opus the probe
    # decodes, at the right level; the silence before it is not sent.
    tone = os.path.join(tempfile.mkdtemp(), "tone.wav")
    subprocess.run(["ffmpeg", "-loglevel", "error", "-y", "-f", "lavfi", "-i", "sine=frequency=440:sample_rate=48000:duration=4",
                    "-ac", "2", tone], check=True)
    def run(proc, token):
        r = probe(["--token-file", token, "--duration", "7", "--windows", "1", "--audio"])
        a = r["audio"]
        if a["packets"] < 180 or a["decoded"] != a["packets"] or a["errors"] or a["channels"] != 2:
            raise Failed(f"audio arrived as {a}")
        if a["peak"] < 0.05:
            raise Failed(f"the tone is missing (peak {a['peak']})")
        # One second of silence is sent, then nothing until the tone: a gap.
        if a["gaps"] < 1 or a["packets"] > 4 * 50 + 2 * 50:
            raise Failed(f"silence was sent: {a}")
        return f"{a['packets']} stereo Opus packets decoded, peak {a['peak']}, silence skipped"
    return with_server(["sh", "-c", f"weston-terminal & sleep 3.5; paplay {tone}; exec sleep 60"], run)


def psnr(a, b):
    out = subprocess.run(["ffmpeg", "-hide_banner", "-i", a, "-i", b, "-lavfi", "psnr", "-f", "null", "-"],
                         capture_output=True, text=True).stderr
    for word in out.split():
        if word.startswith("average:"):
            return float(word.split(":")[1].replace("inf", "99"))
    raise Failed(f"ffmpeg psnr: {out[-300:]}")


def check_refine():
    # A quiet terminal full of text: the keyframe is coded at the normal QP, then once,
    # 300 ms later, the same picture sharpened, then nothing. Measured against a
    # near-lossless reference, the sharpened picture must be clearly closer than the
    # unrefined one.
    text = ["xterm", "-geometry", "100x40", "-e", "sh", "-c", "ls -l /usr/bin | head -38; exec sleep 600"]
    def picture(extra):
        out = tempfile.mkdtemp(prefix="refine-")
        def run(proc, token):
            r = probe(["--token-file", token, "--duration", "3", "--windows", "1", "--save", out])
            return r["windows"][0], os.path.join(out, "window-1.png")
        return with_server(text, run, extra=extra)
    _, reference = picture(("--crf", "1", "--refine-qp", "0"))
    off, soft = picture(("--refine-qp", "0"))
    on, sharp = picture(())
    if off["frames"] != 1 or on["frames"] != 2 or on["keyframes"] != 1:
        raise Failed(f"frames: {off['frames']} without refinement, {on['frames']} ({on['keyframes']} key) with")
    before, after = psnr(soft, reference), psnr(sharp, reference)
    if after < before + 3:
        raise Failed(f"refinement took the picture from {before:.1f} dB to {after:.1f} dB")
    sharpening = (on["bytes"] - off["bytes"]) / 1000
    return f"one sharpening picture ({sharpening:.0f} kB) takes a quiet terminal from {before:.1f} to {after:.1f} dB PSNR"


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
    ("text-input-on-connect", check_text_input_on_connect),
    ("autocorrect", check_autocorrect),
    ("direct-matches-compose", check_direct_matches_compose),
    ("passthrough", check_passthrough),
    ("clipboard-wayland", check_clipboard_wayland),
    ("clipboard-x11", check_clipboard_x11),
    ("clipboard-bridge", check_clipboard_bridge),
    ("audio", check_audio),
    ("refine", check_refine),
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
