#!/usr/bin/env python3
"""Scripted checks for caboose-display against real applications.

Runs in the dev container (guest/display/Dockerfile), or on any Linux host with the
binaries built and weston, xterm, Chromium and Xwayland installed:

    guest/display/scripts/dev.sh python3 scripts/check.py           # everything
    guest/display/scripts/dev.sh python3 scripts/check.py chromium  # by name

Each scenario starts the compositor with an application, connects the headless probe
(which announces a phone, ticks vsync and drives the windows with the phone's input),
and asserts on what arrived: windows, text input state, the clipboard, drag and drop,
sound, and the server's CPU time and memory. Pictures reach the phone through the GPU
path (docs/gpu-live.md), which guest/framelab measures.
"""
import json
import os
import shutil
import struct
import subprocess
import sys
import tempfile
import time
import zlib

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
BIN = os.environ.get("CABOOSE_DISPLAY_BIN", os.path.join(ROOT, "target", "debug"))
PORT = 14600
CHROMIUM = ["chromium", "--ozone-platform=wayland", "--no-sandbox", "--disable-gpu", "--no-first-run",
            "--disable-features=Translate", "--user-data-dir=/tmp/caboose-check-chromium"]
PAGES = "file://" + os.path.join(HERE, "pages")


class Failed(Exception):
    pass


LAST_LOG = None


def log_tail(lines=60, needle=None):
    """The end of the last compositor's log (lines containing `needle`), for a failure."""
    try:
        text = open(LAST_LOG, errors="replace").read().splitlines()
    except (TypeError, OSError):
        return ""
    if needle:
        text = [t for t in text if needle in t]
    return "\n".join(text[-lines:])


def compositor(command, token_file, extra=()):
    env = dict(os.environ)
    env.setdefault("XDG_RUNTIME_DIR", tempfile.mkdtemp(prefix="xdg-"))
    os.chmod(env["XDG_RUNTIME_DIR"], 0o700)
    global LAST_LOG
    LAST_LOG = os.path.join(env["XDG_RUNTIME_DIR"], "caboose-display.log")
    log = open(LAST_LOG, "w")
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
    if not json_out:\
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
        probe(["--token-file", token, "--duration", "3", "--windows", "1", "--type", text + "\n"])
        got = wait_for_file(typed)
        if got != text:
            raise Failed(f"typed {text!r}, terminal read {got!r}")
        return "typed text arrives exactly (key fallback, no text-input-v3)"
    return with_server(["weston-terminal", f"--shell={HERE}/read-line.sh"], run)


def check_physical_key():
    typed = os.path.join(tempfile.mkdtemp(), "typed")
    os.environ["CABOOSE_TYPED"] = typed
    def run(proc, token):
        # The A position (HID 4) wins over a mismatched q keysym; an unknown
        # usage falls back to q. Return finishes the terminal read.
        probe(["--token-file", token, "--duration", "4", "--windows", "1", "--actions",
               "key:71@4;key:71@65535;key:ff0d"])
        got = wait_for_file(typed)
        if got != "aq":
            raise Failed(f"expected physical A then fallback q, got {got!r}")
        return "physical key position and keysym fallback reach the terminal"
    return with_server(["weston-terminal", f"--shell={HERE}/read-line.sh"], run)


def check_x11_terminal():
    typed = os.path.join(tempfile.mkdtemp(), "typed")
    text = "X11 says $HOME ~!@#%^&*()_+{}|:<>? ok"
    def run(proc, token):
        probe(["--token-file", token, "--duration", "3", "--windows", "1", "--type", text + "\n"])
        got = wait_for_file(typed)
        if got != text:
            raise Failed(f"typed {text!r}, xterm read {got!r}")
        return "Xwayland window, typed text arrives exactly"
    env_cmd = ["env", f"CABOOSE_TYPED={typed}", "xterm", "-e", f"{HERE}/read-line.sh"]
    return with_server(env_cmd, run)


def check_taskbar():
    """An X11 window started by a child process, with a class no desktop entry has and a
    _NET_WM_PID from another PID namespace, names its real process and carries its icon,
    which follows the program's change (docs/display.md, "Windows and launches")."""
    pid_file = os.path.join(tempfile.mkdtemp(), "pid")
    def run(proc, token):
        r = probe(["--token-file", token, "--duration", "8", "--windows", "1"])
        real = int(wait_for_file(pid_file))
        window = next((w for w in r["windows"] if w["app_id"] == "CabooseTaskbarCheck"), None)
        if window is None:
            raise Failed(f"no window of class CabooseTaskbarCheck: {[w['app_id'] for w in r['windows']]}")
        if window["pid"] != real:
            raise Failed(f"window pid {window['pid']}, its process is {real} (it claims 2)")
        if window["icon_bytes"] == 0 or window["icons"] < 2:
            raise Failed(f"icon {window['icon_bytes']} bytes, {window['icons']} sent (want the first and the change)")
        return f'class {window["app_id"]}, pid {real} from the X server, icon sent {window["icons"]} times'
    # Through a shell, as a game launcher or a script would start it.
    return with_server(["sh", "-c", f"python3 {HERE}/x11-icon-window.py {pid_file} 20 & wait"], run)


def check_two_windows():
    def run(proc, token):
        r = probe(["--token-file", token, "--duration", "3", "--windows", "2"])
        return f'{len(r["windows"])} windows announced, each its own'
    return with_server(["sh", "-c", "weston-terminal & exec weston-simple-shm"], run)


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


def check_chromium_touch_fling():
    def run(proc, token):
        time.sleep(2)
        # Eight native motion samples, then release; no client-generated wheel inertia.
        actions = ["wait:400", "finger-down:400,600"]
        actions += [f"finger-move:400,{600 - step * 35}" for step in range(1, 9)]
        actions += ["finger-up:400,320"]
        r = probe(["--token-file", token, "--duration", "5", "--windows", "1",
                   "--display", "900x800@60x1", "--actions", ";".join(actions)])
        title = r["windows"][0]["title"]
        if not title.startswith("scroll:"):
            raise Failed(f"native touch never started sampling: {title!r}")
        samples = json.loads(title[len("scroll:"):])
        early = next((y for t, y in samples if t >= 300), None)
        late = samples[-1][1] if samples else None
        if early is None or late is None or early < 100 or late - early < 50:
            raise Failed(f"no sustained native fling: y at 300ms={early}, final={late}; samples={samples}")
        return f"native touch scrolls to {early}px by 300ms, coasts to {late}px after release"
    return with_server(CHROMIUM + ["--window-size=900,800", f"--app={PAGES}/scroll.html"], run)


def check_reconnect():
    def run(proc, token):
        a = probe(["--token-file", token, "--duration", "2", "--windows", "1"])
        b = probe(["--token-file", token, "--duration", "2", "--windows", "1"])
        ids = lambda r: sorted(w["id"] for w in r["windows"])
        if ids(a) != ids(b):
            raise Failed(f"window ids changed across reconnect: {ids(a)} → {ids(b)}")
        return f"same window ids {ids(b)} after reconnect"
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
        p, g = popups[0], popups[0]["geometry"]
        # A popup keeps its alpha; the toplevel is opaque.
        if not p["alpha"] or main[0]["alpha"]:
            raise Failed(f"popup alpha {p['alpha']}, toplevel alpha {main[0]['alpha']}")
        return f"<select> list is its own popup window, parent {main[0]['id']}, at {g} relative to it, with alpha"
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


def png(width, height, rgb=None):
    """An RGB PNG: one colour, or noise (which does not compress) without one."""
    def chunk(kind, data):
        return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data))
    row = (lambda: bytes(rgb) * width) if rgb else (lambda: os.urandom(3 * width))
    rows = b"".join(b"\0" + row() for _ in range(height))
    return (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0))
            + chunk(b"IDAT", zlib.compress(rows)) + chunk(b"IEND", b""))


def fnv1a(data):
    h = 0xcbf29ce484222325
    for b in data:
        h = ((h ^ b) * 0x100000001b3) & 0xFFFFFFFFFFFFFFFF
    return f"{h:016x}"


IMAGE_TYPES = ["--clipboard-types", "image/png,image/jpeg,text/uri-list"]


def clipboard_image(copy_cmd, paste_cmd):
    # Computer -> phone: an application copies a PNG before the phone connects; the phone,
    # which takes images, is sent it on hello, byte for byte, and a text-only phone is not.
    # Phone -> computer: the phone copies another PNG and the application pastes it as
    # image/png, byte for byte.
    work = tempfile.mkdtemp()
    ours, theirs, out = (os.path.join(work, n) for n in ("computer.png", "phone.png", "pasted"))
    open(ours, "wb").write(png(40, 30, (200, 30, 30)))
    open(theirs, "wb").write(png(17, 9, (20, 90, 220)))
    script = (f"xterm & sleep 2; {copy_cmd.format(ours)}; "
              f"while sleep 0.3; do {paste_cmd} > {out}.tmp 2>/dev/null && cmp -s {out}.tmp {theirs} "
              f"&& echo ok > {out} && break; done; exec sleep 60")
    def run(proc, token):
        time.sleep(2)
        text_only = probe(["--token-file", token, "--duration", "2", "--windows", "1"])
        if text_only["clipboard_entries"]:
            raise Failed(f"a text-only phone was sent {text_only['clipboard_entries']}")
        r = probe(["--token-file", token, "--duration", "3", "--windows", "1", *IMAGE_TYPES,
                   "--actions", f"copy-file:image/png:{theirs};wait:500"])
        want = {"mime": "image/png", "bytes": os.path.getsize(ours), "fnv1a": fnv1a(open(ours, "rb").read())}
        if r["clipboard_entries"] != [want]:
            raise Failed(f"the phone got {r['clipboard_entries']}, not the copied PNG {want}")
        wait_for_file(out)
        return "a copied PNG reaches the phone byte for byte (not a text-only phone), and the phone's PNG pastes byte for byte"
    return with_server(["sh", "-c", script], run)


def check_clipboard_image_wayland():
    return clipboard_image("wl-copy --type image/png < {}", "wl-paste --type image/png")


def check_clipboard_image_x11():
    return clipboard_image("xclip -i -selection clipboard -t image/png {}", "xclip -o -selection clipboard -t image/png")


def check_clipboard_x11_large():
    # X11 owners that send big images incrementally (INCR) or vanish. A 6 MiB PNG, which
    # xclip sends in INCR pieces, reaches the phone byte for byte. A 13 MiB one is over
    # the clipboard's limit: nothing reaches the phone and the next copy still does. An
    # owner killed right after copying leaves nothing, and does not stall the next copy.
    work = tempfile.mkdtemp()
    big, huge, out = (os.path.join(work, n) for n in ("big.png", "huge.png", "step"))
    open(big, "wb").write(png(1450, 1450))
    open(huge, "wb").write(png(2100, 2100))
    def step(name, cmd):
        return f"{cmd}; echo {name} > {out}; while [ \"$(cat {out})\" = {name} ]; do sleep 0.2; done"
    script = ("xterm & sleep 2; "
              + step("big", f"xclip -i -selection clipboard -t image/png {big}") + "; "
              + step("huge", f"xclip -i -selection clipboard -t image/png {huge}") + "; "
              + step("text", "printf 'after huge' | xclip -i -selection clipboard") + "; "
              + step("gone", f"xclip -i -selection clipboard -t image/png {big} & p=$!; sleep 0.3; kill $p") + "; "
              + "printf 'after gone' | xclip -i -selection clipboard; echo done > " + out + "; exec sleep 60")
    def advance(expect):
        # The script writes each step's name and waits until it is replaced with "next".
        for _ in range(300):
            if os.path.exists(out) and open(out).read().strip() == expect:
                return
            time.sleep(0.1)
        raise Failed(f"the script never reached {expect!r}")
    def connect(token):
        return probe(["--token-file", token, "--duration", "4", "--windows", "1", *IMAGE_TYPES], timeout=60)
    def run(proc, token):
        advance("big")
        r = connect(token)
        want = {"mime": "image/png", "bytes": os.path.getsize(big), "fnv1a": fnv1a(open(big, "rb").read())}
        if r["clipboard_entries"] != [want]:
            raise Failed(f"the INCR image arrived as {r['clipboard_entries']}, not {want}")
        open(out, "w").write("next")
        advance("huge")
        r = connect(token)
        if any(e["mime"] == "image/png" and e["bytes"] > 12 * 1024 * 1024 for e in r["clipboard_entries"]):
            raise Failed("an image over the limit reached the phone")
        open(out, "w").write("next")
        advance("text")
        r = connect(token)
        if r["clipboard"] != "after huge":
            raise Failed(f"after the oversized image the phone got {r['clipboard']!r}")
        open(out, "w").write("next")
        advance("gone")
        open(out, "w").write("next")
        advance("done")
        r = connect(token)
        if r["clipboard"] != "after gone":
            raise Failed(f"after the owner vanished the phone got {r['clipboard']!r}")
        return ("a 6 MiB X11 image sent by INCR arrives byte for byte; a 13 MiB one is refused and the next copy "
                "arrives; an owner that vanishes does not stall the next copy")
    return with_server(["sh", "-c", script], run)


def check_clipboard_files():
    # Computer -> phone: a file manager's copy (x-special/gnome-copied-files) reaches the
    # phone as a text/uri-list. Phone -> computer: files the phone uploaded to the transfer
    # area paste as text/uri-list and as GNOME's list; a file outside the area is refused
    # and leaves the clipboard as it was.
    transfer = os.path.join(os.path.expanduser("~"), ".cache/caboose/transfers", os.urandom(16).hex())
    os.makedirs(transfer, mode=0o700)
    staged = os.path.join(transfer, "report #1.txt")
    open(staged, "w").write("uploaded")
    out = os.path.join(tempfile.mkdtemp(), "pasted")
    uri = "file://" + staged.replace(" ", "%20").replace("#", "%23")
    script = ("xterm & sleep 2; printf 'copy\n%s' 'file:///home/caboose/Documents/a%20b.odt' | "
              "wl-copy --type x-special/gnome-copied-files; "
              f"while sleep 0.3; do t=$(wl-paste --type x-special/gnome-copied-files 2>/dev/null); "
              f"[ \"$t\" = \"$(printf 'copy\n%s' '{uri}')\" ] && wl-paste --type text/uri-list > {out}.tmp && mv {out}.tmp {out} "
              "&& break; done; exec sleep 60")
    def run(proc, token):
        time.sleep(2)
        r = probe(["--token-file", token, "--duration", "4", "--windows", "1", *IMAGE_TYPES,
                   "--actions", f"copy-files:/etc/hostname;wait:800;copy-files:{staged};wait:800"])
        want = b"file:///home/caboose/Documents/a%20b.odt\r\n"
        if r["clipboard_entries"] != [{"mime": "text/uri-list", "bytes": len(want), "fnv1a": fnv1a(want)}]:
            raise Failed(f"the phone got {r['clipboard_entries']}, not the copied file")
        got = wait_for_file(out)
        if got.strip() != uri:
            raise Failed(f"the computer pasted {got!r}, not {uri!r}")
        return "a file manager's copy reaches the phone as a uri-list; the phone's uploaded file pastes, a file outside the transfer area does not"
    try:
        return with_server(["sh", "-c", script], run)
    finally:
        shutil.rmtree(transfer, ignore_errors=True)


def staged_file(name, content):
    """A file in the transfer area, as the phone uploads it before a copy or a drop."""
    transfer = os.path.join(os.path.expanduser("~"), ".cache/caboose/transfers", os.urandom(16).hex())
    os.makedirs(transfer, mode=0o700)
    path = os.path.join(transfer, name)
    open(path, "w").write(content)
    return transfer, path


def dnd_page(x11=False):
    browser = [a for a in CHROMIUM if not a.startswith("--ozone-platform")]
    return browser + [f"--ozone-platform={'x11' if x11 else 'wayland'}", "--window-size=900,600", f"--app={PAGES}/dnd.html"]


def drop_into(x11):
    # The phone drags a file it uploaded over the page's drop zone: the page (through a
    # real Wayland drag, or XDND for X11) accepts it, and the drop hands it the file.
    # Then text, then a drop over the part of the page that refuses drops.
    transfer, staged = staged_file("report.txt", "uploaded")
    os.environ["CABOOSE_DISPLAY_LOG"] = "caboose_display=debug"
    def run(proc, token):
        time.sleep(4)
        files = probe(["--token-file", token, "--duration", "6", "--windows", "1", *IMAGE_TYPES, "--actions",
                       "drop-enter:text/uri-list@100,300;wait:300;drop-move:130,310;wait:300;drop-move:160,320;wait:800;"
                       f"drop-files:{staged};wait:2500"])
        title, events = files["windows"][0]["title"], files["dnd"]
        if not (title.startswith("drop:") and "Files" in title.split(":")[1] and title.endswith(":report.txt=8")):
            raise Failed(f"the page shows {title!r} after the file drop (events {events})\n{log_tail(80, 'dnd') or log_tail(40)}")
        # A Wayland application answers only once it has the content; an X11 one as the
        # drag hovers.
        if (x11 and "status:true" not in events) or events[-1] != "result:ok":
            raise Failed(f"the drop was not accepted and finished: {events}")
        text = probe(["--token-file", token, "--duration", "6", "--windows", "1", "--actions",
                      "drop-enter:text@100,300;wait:400;drop-move:120,310;wait:1000;"
                      "drop-text:dropped ✓;wait:3000"])
        if text["windows"][0]["title"] != "drop:text/plain:dropped ✓" or text["dnd"][-1] != "result:ok":
            raise Failed(f"the text drop gave {text['windows'][0]['title']!r}, {text['dnd']}\n{log_tail(60, 'ERROR')}\n{log_tail(30, 'WARN')}")
        refused = probe(["--token-file", token, "--duration", "8", "--windows", "1", "--actions",
                         "drop-enter:text@700,150;wait:400;drop-move:710,160;wait:1000;"
                         "drop-text:refused;wait:4500"])
        if refused["dnd"][-1:] != ["result:rejected"]:
            raise Failed(f"a drop on the refusing part was {refused['dnd']}")
        if refused["windows"][0]["title"] != "drop:text/plain:dropped ✓":
            raise Failed(f"the refused drop reached the page: {refused['windows'][0]['title']!r}")
        return ("a file and text from the phone drop into the page under the finger"
                + (", accepted as they hover" if x11 else ", entered once uploaded")
                + "; a drop where the page refuses is rejected")
    try:
        return with_server(dnd_page(x11), run)
    finally:
        os.environ.pop("CABOOSE_DISPLAY_LOG", None)
        shutil.rmtree(transfer, ignore_errors=True)


def check_drop_wayland():
    return drop_into(False)


def check_drop_x11():
    return drop_into(True)


def check_drag_out():
    # The page's draggable is dragged with the pointer; the phone takes it before the
    # release: it gets the text, the drag ends as taken, and the page's own drop zone,
    # where the release happens, receives nothing.
    def run(proc, token):
        time.sleep(4)
        r = probe(["--token-file", token, "--duration", "6", "--windows", "1", *IMAGE_TYPES, "--actions",
                   "press:700,450;move:705,455;move:720,470;move:600,400;move:300,300;wait:600;"
                   "drag-take;release:300,300;wait:2000"])
        events, title = r["dnd"], r["windows"][0]["title"]
        if not any(e.startswith("start:") and "text/plain;charset=utf-8" in e for e in events):
            raise Failed(f"the phone was not told of the drag: {events}")
        if "data:text/plain;charset=utf-8=dragged from Linux" not in events or events[-1] != "end:taken":
            raise Failed(f"the phone did not take the drag: {events}")
        if title.startswith("drop:"):
            raise Failed(f"the taken drag was also dropped on the page: {title!r}")
        return "a drag from Chromium reaches the phone when it takes it, and drops nowhere on the computer"
    return with_server(dnd_page(), run)


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


def server_status(pid):
    fields = dict(line.split(":", 1) for line in open(f"/proc/{pid}/status") if ":" in line)
    return int(fields["Threads"]), int(fields["VmRSS"].split()[0]) // 1024


def probe_cmd(token, *args):
    return [os.path.join(BIN, "caboose-display-probe"), "--url", f"ws://127.0.0.1:{PORT}/", "--token-file", token,
            "--json", *args]


def check_storm():
    # 48 broken connections while a window animates: TCP connections closed at once or
    # left silent, WebSocket handshakes cut short, a wrong token, and clients killed
    # mid-session. Then a normal client must be served as usual, and the server must have
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
        threads1, rss1 = server_status(proc.pid)
        if proc.poll() is not None:
            raise Failed("the server exited")
        if r["rtt_ms"] is None:
            raise Failed(f"the client after the storm was not answered: {r}")
        if threads1 > threads0 + 1 or rss1 > rss0 + 64:
            raise Failed(f"threads {threads0} → {threads1}, RSS {rss0} → {rss1} MB")
        return (f"48 broken connections later a client is served as usual; threads {threads0} → "
                f"{threads1}, RSS {rss0} → {rss1} MB")
    return with_server(["weston-simple-shm"], run)


def check_takeover():
    # Two devices taking the display from each other, six times in a row while a window
    # animates: each newcomer is told of the window, each one replaced is told so.
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
            if not r["windows"]:
                raise Failed(f"client {i} was told of no window: {r}")
            expected = None if i == len(reports) - 1 else "replaced"
            if r["bye"] != expected:
                raise Failed(f"client {i} got bye {r['bye']!r}, expected {expected!r}")
        threads1, _ = server_status(proc.pid)
        if threads1 > threads0 + 1:
            raise Failed(f"threads {threads0} → {threads1}")
        return "6 takeovers: each client was told of the window, each replaced one got bye(replaced)"
    return with_server(["weston-simple-shm"], run)


def check_app_crash():
    # Two animating windows and an xterm; one animation and the xterm are killed with
    # SIGKILL while a client watches. Their windows go, the other stays, and the server
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
        if len(gone) != 2 or len(alive) != 1:
            raise Failed(f"windows after the crash: {r['windows']}")
        after = probe(["--token-file", token, "--duration", "2", "--windows", "1"])
        if proc.poll() is not None or len(after["windows"]) != 1:
            raise Failed(f"after the crash the next client got {len(after['windows'])} windows")
        return "two of three applications killed: their windows went, the survivor stayed"
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
        probe(["--token-file", token, "--duration", "2", "--windows", "1"])
        return f"a stalled client was closed after the timeout, RSS {rss0} → {rss1} MB; the next one was served"
    return with_server(["sh", "-c", "weston-simple-shm & while true; do paplay /dev/urandom --raw 2>/dev/null; sleep 1; done"],
                       run, extra=("--client-timeout", "5"))


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
    ("physical-key", check_physical_key),
    ("x11-terminal", check_x11_terminal),
    ("taskbar", check_taskbar),
    ("two-windows", check_two_windows),
    ("chromium-text-input", check_chromium_text_input),
    ("chromium-touch-fling", check_chromium_touch_fling),
    ("reconnect", check_reconnect),
    ("replace", check_replace),
    ("storm", check_storm),
    ("takeover", check_takeover),
    ("app-crash", check_app_crash),
    ("stalled-client", check_stalled_client),
    ("popup", check_popup),
    ("text-input-on-connect", check_text_input_on_connect),
    ("autocorrect", check_autocorrect),
    ("clipboard-wayland", check_clipboard_wayland),
    ("clipboard-x11", check_clipboard_x11),
    ("clipboard-bridge", check_clipboard_bridge),
    ("clipboard-image-wayland", check_clipboard_image_wayland),
    ("clipboard-image-x11", check_clipboard_image_x11),
    ("clipboard-x11-large", check_clipboard_x11_large),
    ("clipboard-files", check_clipboard_files),
    ("drop-wayland", check_drop_wayland),
    ("drop-x11", check_drop_x11),
    ("drag-out", check_drag_out),
    ("audio", check_audio),
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
