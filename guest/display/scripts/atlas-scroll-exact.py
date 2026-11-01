#!/usr/bin/env python3
"""A store page scrolled on a dense phone: exact atlas pictures, measured.

    guest/display/scripts/dev.sh python3 scripts/atlas-scroll-exact.py
    guest/display/scripts/dev.sh python3 scripts/atlas-scroll-exact.py --rounds 3

Starts the compositor with Chromium drawing in software on X11 (as CEF applications such as
Steam do) showing pages/store.html: a sidebar, a sticky header over a scrolled pane, a hero
and rows of photograph-like artwork. The probe connects as a tablet does (a 1338x1902
display at scale 2, Surface Atlas), scrolls the pane down and back up half way, one precise
scroll input every 300 ms (Chromium on X11 animates each over about 300 ms), lets it rest,
then asks for a keyframe and compares the picture it rebuilt from every batch
with that keyframe, pixel for pixel.

It fails if the rebuilt picture differs anywhere. It prints the latency from a scroll input
to the first picture committed after it (p50, p95), the bytes the server sent from the
first scroll input until the pane rested (per second and per input), and the server's CPU.
"""
import argparse
import os
import shutil
import sys
import tempfile

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import check  # noqa: E402

PHONE = "1338x1902@60x2"
# Window pixels (the picture's, at scale 2): the middle of the scrolled pane.
PANE = "900,1000"


def run(directory, steps, step_px, keep, gpu):
    # Software raster damages what changed; GL output (SwiftShader here, Zink in a
    # computer) presents the whole window every frame, as Steam's client does.
    raster = ["--use-angle=swiftshader", "--enable-unsafe-swiftshader", "--ignore-gpu-blocklist"] if gpu else ["--disable-gpu"]
    chromium = ["chromium", "--ozone-platform=x11", *raster, "--no-sandbox", "--no-first-run",
                f"--user-data-dir={directory}/chromium", f"--app={check.PAGES}/store.html"]
    settle_s = 8
    actions = ["maximize", f"wait:{settle_s * 1000}"]
    # Down the page, then back up half way: a reader flicking through.
    actions += [f"scroll:{PANE},{step_px}" for _ in range(steps)]
    actions += [f"scroll:{PANE},{-step_px}" for _ in range(steps // 2)]
    scrolling_s = (steps + steps // 2) * 0.3 + 1
    verify_at = settle_s + 1 + scrolling_s + 3
    out = tempfile.mkdtemp(prefix="store-", dir=keep or directory)
    result = {}

    def drive(proc, token):
        result["report"] = check.probe([
            "--token-file", token, "--display", PHONE, "--atlas", "--decoders", "hevc,h264",
            "--windows", "1",
            "--server-pid", str(proc.pid), "--duration", f"{verify_at + 3:.1f}", "--actions", ";".join(actions),
            "--verify-atlas", f"{verify_at:.1f}", "--save", out,
        ])

    check.with_server(chromium, drive)
    return result["report"], out


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--rounds", type=int, default=1)
    parser.add_argument("--steps", type=int, default=12)
    parser.add_argument("--step", type=float, default=40.0, help="display pixels per scroll input")
    parser.add_argument("--out", help="keep the probe's pictures (rebuilt, keyframe, last) here")
    parser.add_argument("--gpu", action="store_true", help="Chromium presents through GL (SwiftShader): whole-window damage")
    a = parser.parse_args()
    directory = tempfile.mkdtemp(prefix="atlas-scroll-")
    failed = 0
    try:
        for i in range(a.rounds):
            report, out = run(directory, a.steps, a.step, a.out, a.gpu)
            w = max(report["windows"], key=lambda w: w["surface_batches"])
            verify = report["verify"]
            inputs = a.steps + a.steps // 2
            scroll_kbps = report["scroll_bytes"] * 8 / 1000 / max(report["scroll_seconds"], 0.001)
            print(f"round {i + 1}: {w['size'][0]}x{w['size'][1]}, {w['surface_batches']} batches "
                  f"({w['atlas_copies']} copies, {w['atlas_tiles']} tiles, {w['atlas_refs']} refs), {w['fps']:.1f} fps, "
                  f"scroll to picture p50 {report['input_latency_ms_p50']:.1f} ms p95 {report['input_latency_ms_p95']:.1f} ms "
                  f"({report['input_pictures']} inputs answered), scrolling {scroll_kbps:.0f} kbit/s "
                  f"({report['scroll_bytes'] / 1000 / inputs:.0f} kB per input), "
                  f"server {report['server_cpu_pct']}% of a core")
            if verify is None:
                failed += 1
                print("FAIL no keyframe came to verify against")
            elif verify["diff_px"]:
                failed += 1
                print(f"FAIL the rebuilt picture differs from the keyframe in {verify['diff_px']} pixels, "
                      f"tiles {verify['tiles'][:20]} (pictures in {out})")
    finally:
        if not failed:
            shutil.rmtree(directory, ignore_errors=True)
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
