#!/usr/bin/env python3
"""Server CPU per update for Chromium workloads at phone and TV display sizes.

    guest/display/scripts/dev.sh python3 scripts/profile.py              # everything
    guest/display/scripts/dev.sh python3 scripts/profile.py tv scroll    # filter by name

Each run starts the compositor with Chromium, connects the probe with the display of a
phone or a TV, maximizes the window as the app does, drives it (typing, scrolling, an
idle caret), and prints the server's CPU time per picture, in total and split into
rendering and encoding (from the compositor's own counters), with the picture rate and
bitrate. Extra compositor flags can follow `--`.
"""
import json
import os
import re
import subprocess
import sys
import tempfile
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import check  # noqa: E402

DISPLAYS = {
    "phone": "1179x2556@120x3",
    "tv": "3840x2160@60x2",
}
TYPED = "the caboose rides at the end of the train "


def workloads(width, height):
    mid = f"{width // 2},{height // 2}"
    return {
        "type": ("input.html", ";".join(["maximize", "wait:1500", f"tap:{mid}", "wait:500"]
                                        + [f"text:{c}" for c in TYPED])),
        "scroll": ("article.html", ";".join(["maximize", "wait:1500"]
                                            + [f"scroll:{mid},{dy}" for dy in [120] * 16 + [-120] * 8])),
        "caret": ("input.html", ";".join(["maximize", "wait:1500", f"tap:{mid}", "wait:9000"])),
    }


def threads(pid):
    """CPU seconds per thread name of a process."""
    out = {}
    for tid in os.listdir(f"/proc/{pid}/task"):
        try:
            stat = open(f"/proc/{pid}/task/{tid}/stat").read()
        except OSError:
            continue
        name = stat[stat.index("(") + 1:stat.rindex(")")]
        fields = stat[stat.rindex(")") + 2:].split()
        name = re.sub(r"\d+$", "N", name)
        out[name] = out.get(name, 0) + (int(fields[11]) + int(fields[12])) / os.sysconf("SC_CLK_TCK")
    return out


def process(pid):
    stat = open(f"/proc/{pid}/stat").read()
    fields = stat[stat.rindex(")") + 2:].split()
    return (int(fields[11]) + int(fields[12])) / os.sysconf("SC_CLK_TCK")


def run(display, workload, page, actions, extra):
    os.environ["XDG_RUNTIME_DIR"] = tempfile.mkdtemp(prefix="xdg-")
    os.environ["CABOOSE_DISPLAY_LOG"] = "info"

    def go(proc, token):
        # Threads are sampled while the probe is connected (encoder threads end with
        # the session).
        cmd = [os.path.join(check.BIN, "caboose-display-probe"), "--url", f"ws://127.0.0.1:{check.PORT}/",
               "--token-file", token, "--duration", "11", "--windows", "1", "--display", DISPLAYS[display],
               "--actions", actions, "--server-pid", str(proc.pid), "--json"]
        p = subprocess.Popen(cmd, stdout=subprocess.PIPE, text=True)
        time.sleep(1.5)
        before, total0 = threads(proc.pid), process(proc.pid)
        time.sleep(9)
        after, total1 = threads(proc.pid), process(proc.pid)
        out, _ = p.communicate(timeout=60)
        r = json.loads(out.strip().splitlines()[-1])
        r["threads"] = {n: after[n] - before.get(n, 0) for n in after if after[n] - before.get(n, 0) >= 0.02}
        r["threads"]["(process)"] = total1 - total0
        return r
    r = check.with_server(check.CHROMIUM + [f"--app={check.PAGES}/{page}"], go, extra=extra)
    log = open(os.path.join(os.environ["XDG_RUNTIME_DIR"], "caboose-display.log")).read()
    m = re.search(r"per frame: render ([\d.]+) ms, encode ([\d.]+) ms CPU", log)
    w = max(r["windows"], key=lambda w: w["frames"])
    render, encode = (m.group(1), m.group(2)) if m else ("?", "?")
    print(f"{display:5} {workload:6} {w['size'][0]}x{w['size'][1]}: {w['frames']} pictures, "
          f"{w['kbps']:.0f} kbit/s; server {r['server_cpu_pct']}% of a core, "
          f"{r['server_cpu_ms_per_frame']} ms/picture (render {render}, encode {encode})", flush=True)
    busy = sorted(r["threads"].items(), key=lambda t: -t[1])
    print("      CPU s by thread: " + ", ".join(f"{n} {t:.2f}" for n, t in busy), flush=True)


def main():
    args = sys.argv[1:]
    extra = args[args.index("--") + 1:] if "--" in args else []
    names = args[:args.index("--")] if "--" in args else args
    for display, spec in DISPLAYS.items():
        w, rest = spec.split("x", 1)
        h = rest.split("@")[0]
        for workload, (page, actions) in workloads(int(w), int(h)).items():
            if names and not all(n in (display, workload) for n in names):
                continue
            run(display, workload, page, actions, extra)


if __name__ == "__main__":
    main()
