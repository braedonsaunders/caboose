#!/usr/bin/env python3
"""Finger scrolling in Chromium on X11: a pan moves the page as far as the finger.

    guest/display/scripts/dev.sh python3 scripts/check-finger-scroll.py
    guest/display/scripts/dev.sh python3 scripts/check-finger-scroll.py --step 12 --samples 20

Starts the compositor with Chromium on X11 (as CEF applications such as Steam run)
showing pages/finger-scroll.html. The probe connects as a tablet does (a 1338x1902
display at scale 2) and pans twice, each pan SAMPLES precise scrolls of STEP window
pixels 16 ms apart as a finger sends them, then turns a mouse wheel one click. The page
reports each burst: how far it scrolled, and how long it went on scrolling after its
last wheel event.

It fails unless each pan scrolls the page SAMPLES * STEP / 2 CSS pixels (within 5%)
and stops when the finger does (within 50 ms), and the wheel click scrolls the page
and animates there (more than 50 ms). Through Xwayland, finger scrolling comes from
its touchpad device (guest/xwayland/touchpad-scroll.patch); without it a pan's
samples are wheel steps, each animated and far longer than the pan.
"""
import argparse
import json
import os
import shutil
import sys
import tempfile

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import check  # noqa: E402

PHONE = "1338x1902@60x2"
SCALE = 2
# Window pixels: well inside the maximized window.
AT = "900,1000"


def run(directory, samples, step):
    chromium = ["chromium", "--ozone-platform=x11", "--disable-gpu", "--no-sandbox", "--no-first-run",
                f"--user-data-dir={directory}/chromium", f"--app={check.PAGES}/finger-scroll.html"]
    pan = [f"wheel:{AT},{step}" for _ in range(samples)]
    actions = ["maximize", "wait:6000", *pan, "wait:1500", *pan, "wait:1500", f"notch:{AT},1", "wait:1500"]
    seconds = 6 + 3 * 1.8 + 2 * samples * 0.016 + 3
    result = {}

    def drive(proc, token):
        result["report"] = check.probe([
            "--token-file", token, "--display", PHONE, "--windows", "1",
            "--duration", f"{seconds:.1f}", "--actions", ";".join(actions),
        ])

    check.with_server(chromium, drive)
    title = max(result["report"]["windows"], key=lambda w: len(w["title"]))["title"]
    if not title.startswith("finger-scroll:"):
        raise check.Failed(f"the page never reported: {title!r}")
    return json.loads(title[len("finger-scroll:"):])


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--samples", type=int, default=10, help="precise scrolls per pan")
    parser.add_argument("--step", type=float, default=40.0, help="window pixels per precise scroll")
    a = parser.parse_args()
    directory = tempfile.mkdtemp(prefix="finger-scroll-")
    try:
        bursts = run(directory, a.samples, a.step)
    finally:
        shutil.rmtree(directory, ignore_errors=True)
    want = a.samples * a.step / SCALE
    failures = []
    for i, b in enumerate(bursts):
        kind = "pan" if i < 2 else "wheel click"
        print(f"{kind} {i + 1}: scrolled {b['scrolled']:.1f} CSS px in {b['wheels']} wheel events "
              f"(deltaY {b['deltaY']:.1f}, deltaMode {b['deltaMode']}) over {b['wheel_ms']} ms, "
              f"then went on for {b['tail_ms']} ms")
    if len(bursts) != 3:
        failures.append(f"{len(bursts)} bursts of wheel events, not 2 pans and a wheel click")
    for i, b in enumerate(bursts[:2]):
        if abs(b["scrolled"] - want) > 0.05 * want:
            failures.append(f"pan {i + 1} scrolled {b['scrolled']:.1f} CSS px, not {want:.1f}")
        if b["tail_ms"] > 50:
            failures.append(f"pan {i + 1} went on scrolling {b['tail_ms']} ms after the finger stopped")
    if len(bursts) >= 3 and (bursts[2]["scrolled"] <= 0 or bursts[2]["tail_ms"] <= 50):
        failures.append(f"the wheel click scrolled {bursts[2]['scrolled']:.1f} CSS px over {bursts[2]['tail_ms']} ms, "
                        "not an animated step")
    for f in failures:
        print("FAIL", f)
    sys.exit(1 if failures else 0)


if __name__ == "__main__":
    main()
