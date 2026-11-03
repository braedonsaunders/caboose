#!/usr/bin/env python3
"""Runs WLCS, Mir's Wayland conformance suite, against caboose-display (wlcs/README.md).

    guest/display/scripts/dev.sh python3 scripts/check-wlcs.py [--bin PATH] [--filter GLOB]

Builds the adapter (wlcs/caboose_wlcs.c), runs every WLCS test the compositor's own registry
makes applicable, and compares the failures with wlcs/expected-failures.txt. It fails on a
test that fails and is not listed, and on a listed test that now passes (so the list only
ever names what is really still wrong), and when WLCS itself does not finish.
"""
import argparse
import fnmatch
import glob
import os
import re
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)


def expected_failures(path):
    """The patterns (shell globs of a test's full name) of wlcs/expected-failures.txt."""
    patterns = []
    for line in open(path):
        line = line.split("#", 1)[0].strip()
        if line:
            patterns.append(line)
    return patterns


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--bin", default=os.environ.get("CABOOSE_DISPLAY_BIN", os.path.join(ROOT, "target", "debug", "caboose-display")))
    parser.add_argument("--wlcs", default=(glob.glob("/usr/lib/*/wlcs/wlcs") or ["wlcs"])[0])
    parser.add_argument("--filter", default="*", help="a gtest filter, to run part of the suite (expected failures are then not required to run)")
    parser.add_argument("--timeout", type=int, default=3600)
    parser.add_argument("--from-log", help="compare the failures in the log of an earlier run instead of running")
    args = parser.parse_args()

    work = tempfile.mkdtemp(prefix="caboose-wlcs-check-")
    if args.from_log:
        return compare(args, args.from_log, 0)
    adapter = os.path.join(work, "libcaboose_wlcs.so")
    subprocess.run(["cc", "-shared", "-fPIC", "-O2", "-Wall", "-Wextra", "-Werror", "-o", adapter,
                    os.path.join(ROOT, "wlcs", "caboose_wlcs.c"), "-lwayland-client", "-lpthread"], check=True)
    env = dict(os.environ, CABOOSE_DISPLAY_BIN=args.bin)
    log = os.path.join(work, "wlcs.log")
    with open(log, "w") as out:
        try:
            run = subprocess.run([args.wlcs, adapter, f"--gtest_filter={args.filter}"], env=env, stdout=out,
                                 stderr=subprocess.STDOUT, timeout=args.timeout)
        except subprocess.TimeoutExpired:
            print(f"FAIL: wlcs did not finish within {args.timeout} s; log: {log}")
            return 1
    return compare(args, log, run.returncode)


def compare(args, log, returncode):
    text = open(log, errors="replace").read()
    passed = set(re.findall(r"^\[       OK \] (\S+)", text, re.M))
    failed = set(re.findall(r"^\[  FAILED  \] (\S+)$", text, re.M))
    if not re.search(r"^\[==========\] \d+ tests? from .* run", text, re.M):
        print(text[-3000:])
        print(f"FAIL: wlcs ended without a summary (exit {returncode}); log: {log}")
        return 1
    patterns = expected_failures(os.path.join(ROOT, "wlcs", "expected-failures.txt"))
    listed = lambda name: any(fnmatch.fnmatchcase(name, p) for p in patterns)
    unexpected = sorted(n for n in failed if not listed(n))
    fixed = sorted(n for n in passed if listed(n))
    stale = sorted(p for p in patterns if not any(fnmatch.fnmatchcase(n, p) for n in failed)) if args.filter == "*" else []
    print(f"WLCS: {len(passed)} passed, {len(failed)} failed ({len(failed) - len(unexpected)} expected); log: {log}")
    ok = True
    if unexpected:
        ok = False
        print("FAIL: tests that fail and are not in wlcs/expected-failures.txt:")
        for name in unexpected:
            print(f"  {name}")
    if fixed:
        ok = False
        print("FAIL: tests that pass although wlcs/expected-failures.txt lists them; narrow the pattern:")
        for name in fixed:
            print(f"  {name}")
    if stale:
        ok = False
        print("FAIL: patterns in wlcs/expected-failures.txt that match no failing test; remove them:")
        for name in stale:
            print(f"  {name}")
    if ok:
        print("PASS")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
