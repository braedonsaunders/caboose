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


def check_reconnect_idle():
    # A window streamed in place from its shm buffer (xterm: one surface, even size) that
    # draws nothing between two clients: the second client's keyframe must still be the
    # window's picture, read from the buffer.
    def run(proc, token):
        pictures = []
        for _ in range(2):
            out = tempfile.mkdtemp(prefix="idle-")
            probe(["--token-file", token, "--duration", "2", "--windows", "1", "--save", out])
            pictures.append(open(os.path.join(out, "window-1.png"), "rb").read())
            time.sleep(1)
        if pictures[0] != pictures[1]:
            raise Failed("the second client's picture of an idle window differs from the first's")
        return f"an idle window's picture is the same for a second client ({len(pictures[1])} byte PNG)"
    return with_server(["xterm", "-geometry", "80x24", "-e", "sh", "-c", "ls -l /usr/bin | head -20; exec sleep 600"], run)


def check_replace():
    def run(proc, token):
        first = subprocess.Popen(
            [os.path.join(BIN, "caboose-display-probe"), "--url", f"ws://127.0.0.1:{PORT}/", "--token-file", token,
             "--duration", "6", "--json"], stdout=subprocess.PIPE, text=True)
        time.sleep(2)
        probe(["--token-file", token, "--duration", "2", "--windows", "1"])
        out, _ = first.communicate(timeout=30)
        report = json.loads(out.strip().splitlines()[-1])
        if report["bye"] != "replaced":
            raise Failed(f"the replaced client got bye {report['bye']!r}")
        return "a second client takes over; the first gets bye(replaced)"
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
    # unrefined one. A blinking caret must not cost a sharpening picture per blink.
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
    def blinking(extra):
        def run(proc, token):
            time.sleep(3)
            return probe(["--token-file", token, "--duration", "6", "--windows", "1"])["windows"][0]["frames"]
        return with_server(CHROMIUM + ["--window-size=900,400", f"--app={PAGES}/input.html"], run, extra=extra)
    plain, sharpened = blinking(("--refine-qp", "0")), blinking(())
    if sharpened > plain + 4:
        raise Failed(f"a blinking caret took {sharpened} pictures in 6 s with sharpening, {plain} without")
    return (f"one sharpening picture ({sharpening:.0f} kB) takes a quiet terminal from {before:.1f} to {after:.1f} dB "
            f"PSNR; a blinking caret: {sharpened} pictures in 6 s, {plain} without sharpening")


def check_motion():
    # Chromium plays a 480x270 canvas "video" for 8 s within a page of text. Its region
    # must become a motion stream, close to the canvas, whose every frame decodes; the
    # window stream must carry little meanwhile; the stream must end once the video
    # stops; and the window's final picture (the region put back) must match the one
    # streamed without motion detection.
    runs = {}
    for name, extra in (("motion", ()), ("window only", ("--no-motion",))):
        out = tempfile.mkdtemp(prefix="motion-")
        def run(proc, token, out=out):
            r = probe(["--token-file", token, "--duration", "13", "--windows", "1", "--video-decoders", "h264",
                       "--server-pid", str(proc.pid), "--save", out])
            return r, os.path.join(out, "window-1.png")
        runs[name] = with_server(CHROMIUM + ["--window-size=1280,720", f"--app={PAGES}/movie.html#240"], run,
                                 extra=extra)
    (r, picture), (plain, plain_picture) = runs["motion"], runs["window only"]
    if len(r["videos"]) != 1 or r["videos"][0]["source"] != "motion":
        raise Failed(f"expected one motion stream: {r['videos']}")
    v, window = r["videos"][0], r["windows"][0]
    x, y, w, h = v["rect"]
    # The canvas is 480x270 at x=160 (y below Chromium's infobar), regions are whole
    # macroblocks.
    if v["window"] != window["id"] or abs(x - 160) > 16 or abs(w - 480) > 32 or abs(h - 270) > 32:
        raise Failed(f"motion stream at {v['rect']} in window {v['window']}, expected about 480x270 at x=160")
    if v["frames"] < 120 or v["decoded"] != v["frames"] or v["decode_errors"] or v["timed"] != v["frames"]:
        raise Failed(f"motion frames {v['frames']}, decoded {v['decoded']}, errors {v['decode_errors']}, "
                     f"with pts {v['timed']}")
    if not v["keyframe_first"] or not v["destroyed"]:
        raise Failed(f"keyframe first {v['keyframe_first']}, ended {v['destroyed']}")
    if window["frames"] * 2 > v["frames"]:
        raise Failed(f"the window stream sent {window['frames']} pictures beside {v['frames']} motion frames")
    match = psnr(picture, plain_picture)
    if match < 40:
        raise Failed(f"the window after the motion stream differs from the window-only stream ({match:.1f} dB)")
    return (f"{v['frames']} motion frames at {v['rect']}, {window['frames']} window pictures beside them; "
            f"server {r['server_cpu_pct']}% of a core, {plain['server_cpu_pct']}% without motion streams; "
            f"the final pictures match at {match:.1f} dB")


def server_status(pid):
    fields = dict(line.split(":", 1) for line in open(f"/proc/{pid}/status") if ":" in line)
    return int(fields["Threads"]), int(fields["VmRSS"].split()[0]) // 1024


def probe_cmd(token, *args):
    return [os.path.join(BIN, "caboose-display-probe"), "--url", f"ws://127.0.0.1:{PORT}/", "--token-file", token,
            "--json", *args]


def check_storm():
    # 48 broken connections while a window animates: TCP connections closed at once or
    # left silent, WebSocket handshakes cut short, a wrong token, and clients killed
    # mid-stream. Then a normal client must be served as usual, and the server must have
    # let go of what the broken ones held.
    import socket
    def run(proc, token):
        probe(["--token-file", token, "--duration", "1", "--windows", "1"])
        threads0, rss0 = server_status(proc.pid)
        silent = []
        for i in range(48):
            kind = i % 6
            if kind == 0:
                socket.create_connection(("127.0.0.1", PORT)).close()
            elif kind == 1:
                silent.append(socket.create_connection(("127.0.0.1", PORT)))
            elif kind == 2:
                c = socket.create_connection(("127.0.0.1", PORT))
                c.sendall(b"GET / HTTP/1.1\r\nHost: x\r\nUpgrade: websocket\r\n")
                c.close()
            elif kind == 3:
                probe(["--token", "wrong", "--duration", "1"], check=False)
            else:
                p = subprocess.Popen(probe_cmd(token, "--duration", "5"), stdout=subprocess.DEVNULL)
                time.sleep(0.3 + 0.2 * (i % 3))
                p.kill()
                p.wait()
        time.sleep(1)
        for c in silent:
            c.close()
        time.sleep(4)
        r = probe(["--token-file", token, "--duration", "3", "--windows", "1"])
        w = r["windows"][0]
        threads1, rss1 = server_status(proc.pid)
        if proc.poll() is not None:
            raise Failed("the server exited")
        if not w["keyframe_first"] or w["fps"] < 50 or w["decode_errors"]:
            raise Failed(f"the client after the storm: {w}")
        if threads1 > threads0 + 1 or rss1 > rss0 + 64:
            raise Failed(f"threads {threads0} → {threads1}, RSS {rss0} → {rss1} MB")
        return (f"48 broken connections later a client streams at {w['fps']:.0f} fps; threads {threads0} → "
                f"{threads1}, RSS {rss0} → {rss1} MB")
    return with_server(["weston-simple-shm"], run)


def check_takeover():
    # Two devices taking the display from each other, six times in a row while a window
    # animates: each newcomer starts with a keyframe, each one replaced is told so.
    def run(proc, token):
        threads0, _ = server_status(proc.pid)
        clients = []
        for _ in range(6):
            clients.append(subprocess.Popen(probe_cmd(token, "--duration", "8", "--windows", "1"),
                                            stdout=subprocess.PIPE, text=True))
            time.sleep(1.2)
        reports = []
        for c in clients:
            out, _ = c.communicate(timeout=30)
            reports.append(json.loads(out.strip().splitlines()[-1]))
        for i, r in enumerate(reports):
            w = r["windows"][0] if r["windows"] else None
            if not w or not w["keyframe_first"] or w["frames"] < 30 or w["decode_errors"]:
                raise Failed(f"client {i}: {w}")
            expected = None if i == len(reports) - 1 else "replaced"
            if r["bye"] != expected:
                raise Failed(f"client {i} got bye {r['bye']!r}, expected {expected!r}")
        threads1, _ = server_status(proc.pid)
        if threads1 > threads0 + 1:
            raise Failed(f"threads {threads0} → {threads1}")
        return f"6 takeovers: each client began with a keyframe, each replaced one got bye(replaced)"
    return with_server(["weston-simple-shm"], run)


def check_resize_streaming():
    # Chromium animating while the client resizes its window ten times, 300 ms apart:
    # every size starts with a keyframe, nothing fails to decode, the last size sticks.
    sizes = [(800, 600), (1200, 700), (640, 480), (1280, 800), (900, 900), (700, 1000), (1000, 560),
             (1180, 720), (720, 720), (1024, 768)]
    actions = ";".join(f"resize:{w},{h}" for w, h in sizes) + ";wait:1500"
    def run(proc, token):
        r = probe(["--token-file", token, "--duration", "7", "--windows", "1", "--actions", actions])
        w = r["windows"][0]
        if w["decode_errors"] or not w["keyframe_after_resize"]:
            raise Failed(f"decode errors {w['decode_errors']}, a size without a keyframe: {not w['keyframe_after_resize']}")
        if w["sizes"] < 6 or tuple(w["size"][:2]) != (1024, 768):
            raise Failed(f"{w['sizes']} sizes seen, ending at {w['size']}")
        return f"{w['sizes']} sizes while animating, each from a keyframe, ending at {w['size'][0]}x{w['size'][1]}"
    return with_server(CHROMIUM + ["--window-size=1000,700", f"--app={PAGES}/motion.html"], run)


def check_app_crash():
    # Two animating windows and an xterm; one animation and the xterm are killed with
    # SIGKILL mid-stream. Their windows go, the other keeps streaming, and the server
    # serves the next client the survivor.
    pids = tempfile.mkdtemp(prefix="crash-")
    launcher = (f"weston-simple-shm & echo $! > {pids}/a; weston-simple-shm & echo $! > {pids}/b; "
                f"xterm & echo $! > {pids}/x; exec sleep 600")
    def run(proc, token):
        c = subprocess.Popen(probe_cmd(token, "--duration", "6", "--windows", "3"), stdout=subprocess.PIPE, text=True)
        time.sleep(2.5)
        for name in ("a", "x"):
            os.kill(int(open(f"{pids}/{name}").read()), 9)
        out, _ = c.communicate(timeout=30)
        r = json.loads(out.strip().splitlines()[-1])
        gone = [w for w in r["windows"] if w["destroyed"]]
        alive = [w for w in r["windows"] if not w["destroyed"]]
        if len(gone) != 2 or len(alive) != 1 or any(w["decode_errors"] for w in r["windows"]):
            raise Failed(f"windows after the crash: {r['windows']}")
        if alive[0]["frames"] < 250:
            raise Failed(f"the survivor sent only {alive[0]['frames']} frames in 6 s")
        after = probe(["--token-file", token, "--duration", "2", "--windows", "1"])
        if proc.poll() is not None or len(after["windows"]) != 1:
            raise Failed(f"after the crash the next client got {len(after['windows'])} windows")
        return "two of three applications killed mid-stream: their windows went, the survivor streamed on"
    return with_server(["sh", "-c", launcher], run)


def established(port):
    """Established TCP connections to `port` on this machine."""
    n = 0
    for table in ("/proc/net/tcp", "/proc/net/tcp6"):
        for line in open(table).read().splitlines()[1:]:
            local, state = line.split()[1], line.split()[3]
            n += state == "01" and int(local.split(":")[1], 16) == port
    return n


def check_stalled_client():
    # A client that stops reading while sound plays (a phone suspended with its socket
    # open): the server must not queue for it without bound, and closes it once it has
    # been silent for --client-timeout (5 s here). The next client is served as usual.
    def run(proc, token):
        c = subprocess.Popen(probe_cmd(token, "--duration", "16", "--windows", "1", "--audio", "--stall-after", "2"),
                             stdout=subprocess.DEVNULL)
        time.sleep(2.5)
        _, rss0 = server_status(proc.pid)
        held = established(PORT)
        # 5 s of silence, the next once-a-second check, then 3 s for the close handshake
        # the stalled peer never answers.
        time.sleep(10)
        _, rss1 = server_status(proc.pid)
        left = established(PORT)
        c.kill()
        c.wait()
        if held < 1 or left != 0:
            raise Failed(f"{held} connection(s) while stalled, {left} after the timeout")
        if rss1 > rss0 + 32:
            raise Failed(f"RSS grew {rss0} → {rss1} MB for a stalled client")
        r = probe(["--token-file", token, "--duration", "2", "--windows", "1"])
        if not r["windows"][0]["keyframe_first"]:
            raise Failed("the next client did not start with a keyframe")
        return f"a stalled client was closed after the timeout, RSS {rss0} → {rss1} MB; the next one was served"
    return with_server(["sh", "-c", "weston-simple-shm & while true; do paplay /dev/urandom --raw 2>/dev/null; sleep 1; done"],
                       run, extra=("--client-timeout", "5"))


def check_tiles():
    # Typing 30 characters into Chromium at a phone's size: each keystroke must go as a
    # few lossless tiles instead of a picture, every tile must decode, the final picture
    # (frame plus tiles, as the client paints it) must match the one streamed without
    # tiles, and the server must spend far less on it.
    typed = "tiles are lossless and cheap ok"
    actions = ";".join(["maximize", "wait:1500", "tap:590,1278", "wait:600"] + [f"text:{c}" for c in typed]
                       + ["wait:400"])
    runs = {}
    for name, extra in (("tiles", ()), ("pictures", ("--tile-max-px", "0"))):
        out = tempfile.mkdtemp(prefix="tiles-")
        def run(proc, token, out=out):
            r = probe(["--token-file", token, "--duration", "14", "--windows", "1", "--display", "1179x2556@120x3",
                       "--actions", actions, "--server-pid", str(proc.pid), "--save", out])
            return r, os.path.join(out, "window-1.png")
        runs[name] = with_server(CHROMIUM + [f"--app={PAGES}/input.html"], run, extra=extra)
    (r, picture), (plain, plain_picture) = runs["tiles"], runs["pictures"]
    w, p = r["windows"][0], plain["windows"][0]
    if w["tiles"] < len(typed) or w["tile_errors"] or w["decode_errors"]:
        raise Failed(f"{w['tiles']} tiles for {len(typed)} keystrokes, {w['tile_errors']} bad")
    if w["frames"] * 3 > p["frames"]:
        raise Failed(f"{w['frames']} pictures with tiles against {p['frames']} without")
    match = psnr(picture, plain_picture)
    if match < 40:
        raise Failed(f"the picture with tiles differs from the one without ({match:.1f} dB)")
    cpu, plain_cpu = r["server_cpu_ms"], plain["server_cpu_ms"]
    if cpu > 0.6 * plain_cpu:
        raise Failed(f"server CPU {cpu} ms with tiles, {plain_cpu} ms without")
    # A small animation (250x250 at 60 Hz) changes as little each time, but goes as video.
    anim = with_server(["weston-simple-shm"], lambda proc, token: probe(
        ["--token-file", token, "--duration", "4", "--windows", "1"]))["windows"][0]
    # (Its first updates go as tiles until it shows itself an animation.)
    if anim["tile_bytes"] > 1_000_000 or anim["fps"] < 50:
        raise Failed(f"an animation went as {anim['tile_bytes'] // 1000} kB of tiles, {anim['fps']} pictures a second")
    return (f"{len(typed)} keystrokes at 1179x2556: {w['tiles']} tiles ({w['tile_bytes'] // 1000} kB) and "
            f"{w['frames']} pictures, against {p['frames']} pictures; server {cpu} ms against {plain_cpu} ms; "
            f"final pictures match at {match:.1f} dB; an animation stays video ({anim['fps']:.0f} fps, {anim['tile_bytes'] // 1000} kB of tiles at its start)")


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
    ("reconnect-idle", check_reconnect_idle),
    ("replace", check_replace),
    ("storm", check_storm),
    ("takeover", check_takeover),
    ("resize-streaming", check_resize_streaming),
    ("app-crash", check_app_crash),
    ("stalled-client", check_stalled_client),
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
    ("motion", check_motion),
    ("tiles", check_tiles),
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
