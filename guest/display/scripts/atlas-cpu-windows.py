#!/usr/bin/env python3
"""CPU-drawn windows on a phone: lossless atlas pictures, exact.

    guest/display/scripts/dev.sh python3 scripts/atlas-cpu-windows.py              # everything
    guest/display/scripts/dev.sh python3 scripts/atlas-cpu-windows.py writer      # by name

Each scenario starts the compositor with an application that draws on the CPU
(LibreOffice Writer, a GTK 3 text view, Chromium in software on X11 as CEF applications such
as Steam draw, xterm; on Wayland and on X11), connects the probe as the phone does (a
1179x2556 display at scale 3, Surface Atlas), maximizes the window and scrolls it as a
trackpad does, a step every 16 ms for five seconds (Chromium's page scrolls itself). Then it
asks for a keyframe and fails if the picture rebuilt from every batch differs from it in any
pixel, or if the picture came as video. It prints the window's picture size, rate, bandwidth
and latency, and the server's CPU.

LibreOffice and the GTK text view need `libreoffice-writer libreoffice-gtk3` and
`python3-gi gir1.2-gtk-3.0` in the container.
"""
import os
import shutil
import sys
import tempfile

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import check  # noqa: E402

PHONE = "1179x2556@120x3"
WIDTH, HEIGHT = 1179 // 3, 2556 // 3
LINES = 600

TEXT_VIEW = r"""
import gi, sys
gi.require_version("Gtk", "3.0")
from gi.repository import Gtk
w = Gtk.Window(title="text")
w.set_default_size(380, 800)
s = Gtk.ScrolledWindow()
v = Gtk.TextView()
v.get_buffer().set_text("\n".join(f"{i:4} the caboose rides at the end of the train, its lamps lit" for i in range(%d)))
s.add(v)
w.add(s)
w.connect("destroy", Gtk.main_quit)
w.show_all()
Gtk.main()
""" % LINES


def writer_document(directory):
    paragraphs = "".join(
        f"<text:p>{i:4}. The caboose rides at the end of the train; its crew watches the cars ahead "
        f"for hot boxes, shifted loads and dragging equipment.</text:p>"
        for i in range(LINES))
    path = os.path.join(directory, "train.fodt")
    with open(path, "w", encoding="utf-8") as f:
        f.write('<?xml version="1.0" encoding="UTF-8"?>'
                '<office:document xmlns:office="urn:oasis:names:tc:opendocument:xmlns:office:1.0" '
                'xmlns:text="urn:oasis:names:tc:opendocument:xmlns:text:1.0" office:version="1.3" '
                'office:mimetype="application/vnd.oasis.opendocument.text">'
                f'<office:body><office:text>{paragraphs}</office:text></office:body></office:document>')
    return path


def scenarios(directory):
    view = os.path.join(directory, "text-view.py")
    with open(view, "w", encoding="utf-8") as f:
        f.write(TEXT_VIEW)
    doc = writer_document(directory)
    writer = ["soffice", "--writer", "--norestore", "--nologo", "--nodefault", f"-env:UserInstallation=file://{directory}/lo", doc]
    return {
        "writer-wayland": (["env", "SAL_USE_VCLPLUGIN=gtk3", "GDK_BACKEND=wayland", *writer], 25),
        "writer-x11": (["env", "SAL_USE_VCLPLUGIN=gen", *writer], 25),
        "gtk3-wayland": (["env", "GDK_BACKEND=wayland", "python3", view], 4),
        "gtk3-x11": (["env", "GDK_BACKEND=x11", "python3", view], 4),
        # Chromium drawing in software on X11, as CEF applications (Steam) do.
        "chromium-x11": (["chromium", "--ozone-platform=x11", "--disable-gpu", "--no-sandbox", "--no-first-run",
                          f"--user-data-dir={directory}/chromium", f"file://{check.HERE}/pages/autoscroll.html"], 8),
        "xterm": (["xterm", "-sl", "5000", "-geometry", "60x60", "-e", "sh", "-c", f"seq 1 {LINES * 4}; exec sleep 600"], 4),
    }


def run(name, command, settle_s):
    # Window pixels: the middle of the maximized window at scale 3.
    mid = f"{WIDTH * 3 // 2},{HEIGHT * 3 // 2}"
    steps = 5000 // 16
    actions = ["maximize", f"wait:{settle_s * 1000}"]
    # Down for half the time, back up for the other half: a reader flicking through.
    actions += [f"wheel:{mid},{30 if i < steps // 2 else -30}" for i in range(steps)]
    result = {}

    def drive(proc, token):
        report = check.probe([
            "--token-file", token, "--display", PHONE, "--atlas", "--decoders", "hevc,h264", "--windows", "1",
            "--server-pid", str(proc.pid), "--duration", str(settle_s + 12), "--actions", ";".join(actions),
            "--verify-atlas", str(settle_s + 9),
        ])
        result["report"] = report

    check.with_server(command, drive)
    report = result["report"]
    w = max(report["windows"], key=lambda w: w["surface_batches"] + w["frames"])
    print(f"{name}: {w['size'][0]}x{w['size'][1]} {w['codec']}, {w['surface_batches']} batches "
          f"({w['atlas_copies']} copies, {w['atlas_tiles']} tiles, {w['atlas_refs']} refs), {w['fps']:.1f} fps, "
          f"{w['kbps']:.0f} kbit/s, latency p50 {w['latency_ms_p50']:.1f} ms p95 {w['latency_ms_p95']:.1f} ms, "
          f"server {report['server_cpu_pct']}% of a core")
    verify = report["verify"]
    if verify is None or verify["diff_px"]:
        raise check.Failed(f"{name}: the rebuilt picture is not the keyframe's: {verify}")
    if w["codec"] != "atlas":
        raise check.Failed(f"{name}: the window picture came as {w['codec']} video")


def main():
    wanted = sys.argv[1:]
    directory = tempfile.mkdtemp(prefix="atlas-cpu-")
    failed = 0
    try:
        for name, (command, settle_s) in scenarios(directory).items():
            if wanted and not any(w in name for w in wanted):
                continue
            program = next(c for c in command if c != "env" and "=" not in c)
            if shutil.which(program) is None:
                print(f"{name}: skipped, {program} is not installed")
                continue
            try:
                run(name, command, settle_s)
            except check.Failed as e:
                failed += 1
                print(f"FAIL {e}")
    finally:
        shutil.rmtree(directory, ignore_errors=True)
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
