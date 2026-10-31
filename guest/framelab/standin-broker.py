#!/usr/bin/env python3
"""A stand-in for the GPU broker's present timeline, for check.sh only.

    standin-broker.py GPU_DIR LOG

Writes the real broker's present trace (caboose-gpu-broker's PresentTrace, loaded from
GPU_DIR/gfxstream) to LOG at 50 presents a second, each followed by its result 10 ms
later, with the stream bytes, for as long as it runs; the trace itself only writes while
$XDG_RUNTIME_DIR/caboose-gpu-present-trace exists, as in the broker. It checks the path
from the broker's stderr to frame lab's scorecard without a phone; the presents are
synthetic and belong to no application.
"""
import contextlib
import importlib.util
from importlib.machinery import SourceFileLoader
from pathlib import Path
import sys
import time

gpu, log = Path(sys.argv[1]), sys.argv[2]
sys.path[:0] = [str(gpu / 'broker'), str(gpu / 'gfxstream')]
loader = SourceFileLoader('caboose_gpu_broker', str(gpu / 'gfxstream/caboose-gpu-broker'))
spec = importlib.util.spec_from_loader(loader.name, loader)
broker = importlib.util.module_from_spec(spec)
loader.exec_module(broker)

with open(log, 'a', buffering=1) as out, contextlib.redirect_stderr(out):
    trace = broker.PresentTrace()
    present, result = int(broker.Kind.SWAPCHAIN_PRESENT), int(broker.Kind.PRESENT_RESULT)
    while True:
        trace.surface('received_from_guest', present)
        trace.stream(to_phone=48_000)
        time.sleep(0.01)
        trace.surface('received_from_phone', result)
        trace.stream(from_phone=64)
        time.sleep(0.01)
