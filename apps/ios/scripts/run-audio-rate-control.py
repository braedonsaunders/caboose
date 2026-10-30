#!/usr/bin/env python3
"""Run the explicitly supplied standalone control binary; never compiles or captures."""
import argparse
import os
import signal
import subprocess
import sys


def interrupt(_signum, _frame):
    raise KeyboardInterrupt


def stop_group(child, sig):
    try:
        os.killpg(child.pid, sig)
    except ProcessLookupError:
        pass  # The owned child exited between poll and signal.


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", required=True, help="Previously compiled audio-rate-control executable")
    args = parser.parse_args()
    env = os.environ.copy()
    env["CABOOSE_AUDIO_RATE_CONTROL"] = "1"
    signal.signal(signal.SIGTERM, interrupt)
    child = subprocess.Popen([os.path.abspath(args.binary)], env=env, start_new_session=True)
    try:
        return child.wait(timeout=90)
    except subprocess.TimeoutExpired:
        print("Audio rate control exceeded its 90-second deadline; result is incomplete.", file=sys.stderr)
        return 124
    except KeyboardInterrupt:
        return 130
    finally:
        if child.poll() is None:
            # This process group belongs solely to the child launched above.
            stop_group(child, signal.SIGTERM)
            try:
                child.wait(timeout=2)
            except subprocess.TimeoutExpired:
                stop_group(child, signal.SIGKILL)
                child.wait()


if __name__ == "__main__":
    sys.exit(main())
