#!/usr/bin/env python3
"""Opt-in legacy marker protocol fixture, never production admission enablement.
Requires compositor and probe built together from pinned legacy source 7f3b94796bcc1e691ac39a5754048fe26ddd158f, in an isolated fixture environment.
Current production binaries correctly fail this historical behavior check.
"""
import argparse
from check import CHROMIUM, HERE, Failed, probe, with_server
import os
import shutil
import subprocess
import tempfile
import time

def check_marker_binding():
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


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--legacy-marker-binding", required=True, action="store_true")
    parser.parse_args()
    if not os.environ.get("CABOOSE_DISPLAY_BIN"):
        parser.error("set CABOOSE_DISPLAY_BIN to explicitly selected isolated legacy test binaries")
    print(check_marker_binding())
