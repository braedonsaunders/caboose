#!/usr/bin/env python3
"""The phone's last executor session negotiated every GPU feature the installed release expects.

    python3 check_session_features.py COMPUTER [--expect-file FILE] [--log PATH]

COMPUTER is a running computer container. Its display log (PATH, the owner display's by
default) holds one CABOOSE_GPU_SESSION_FEATURES line per executor session and each process's
CABOOSE_GPU_HELLO; the release's expected-features.json (FILE, the installed one by default)
holds what a phone session must reach. The last session that came through the host relay is
compared with it, and each missing feature is named with the component that dropped it: the
phone app (did not declare it), the host relay (did not forward it), the broker's admission
(did not admit it) or the hello (the driver did not offer it or the broker did not grant it).
Exit 0 when everything matches, 1 on a mismatch, 2 when there is no phone session to check
(docs/gpu-live.md, "Feature negotiation").
"""
import argparse
import json
import re
import subprocess
import sys

INSTALLED = '/usr/local/libexec/caboose-gpu/expected-features.json'
DISPLAY_LOG = '/home/caboose/.cache/caboose-display.log'
SESSION = re.compile(r'CABOOSE_GPU_SESSION_FEATURES source=(\S+) declared=(\S+) forwarded=(\S+) received=(\S+) bits=(\S+)')
HELLO = re.compile(r'CABOOSE_GPU_HELLO features=(0x[0-9a-f]+)')


def names(field):
    return set() if field == '-' else set(field.split(','))


def findings(lines, expected):
    """(problems, summary) for the log `lines` against `expected`; problems is None when no
    session came through the relay."""
    session_at, session = None, None
    for at, line in enumerate(lines):
        match = SESSION.search(line)
        if match and match.group(1) == 'relay':
            session_at, session = at, match
    if session is None:
        # A broker that predates the session line: the processes' hellos still show the result.
        hellos = [int(m.group(1), 16) for line in lines for m in [HELLO.search(line)] if m]
        if not hellos:
            return None, 'no executor session through the host relay in the log'
        want, got = int(expected['hello_features'], 16), hellos[-1]
        summary = f'hello={got:#x} expected={want:#x} (no CABOOSE_GPU_SESSION_FEATURES line: the broker predates it)'
        if not want & ~got:
            return [], summary
        missing = [n for n, b in expected.get('hello_bits', {}).items() if want & ~got & int(b, 16)] or [f'{want & ~got:#x}']
        return [f'hello {got:#x} lacks {", ".join(sorted(missing))}: dropped by the phone app, the host relay, '
                'the broker or the driver (this broker does not log which)'], summary
    declared, forwarded, received = (names(session.group(i)) for i in (2, 3, 4))
    problems = []
    for name in sorted(set(expected['phone_features']) - received):
        if name not in declared:
            problems.append(f'{name}: the phone app did not declare it (install the release\'s phone app)')
        elif name not in forwarded:
            problems.append(f'{name}: the host relay dropped it (apps/host/src/gpu-relay.ts; deploy the host from the release)')
        else:
            problems.append(f'{name}: the broker\'s admission dropped it (guest/gpu/gfxstream/gpu_admission.py)')
    want = int(expected['hello_features'], 16)
    hellos = [int(m.group(1), 16) for line in lines[session_at + 1:] for m in [HELLO.search(line)] if m]
    summary = f'session declared={len(declared)} forwarded={len(forwarded)} received={len(received)} bits={session.group(5)}'
    if hellos:
        got = hellos[-1]
        summary += f' hello={got:#x} expected={want:#x}'
        if want & ~got:
            bits = expected.get('hello_bits', {})
            missing = [n for n, b in bits.items() if want & ~got & int(b, 16)] or [f'{want & ~got:#x}']
            problems.append(f'hello {got:#x} lacks {", ".join(sorted(missing))}: the driver did not offer them or the broker did not grant them')
    else:
        summary += ' (no process hello after the session yet)'
    return problems, summary


def main(argv):
    parser = argparse.ArgumentParser(description=__doc__.split('\n\n')[0])
    parser.add_argument('computer')
    parser.add_argument('--expect-file', help=f'expected-features.json (default: the computer\'s {INSTALLED})')
    parser.add_argument('--log', default=DISPLAY_LOG)
    args = parser.parse_args(argv[1:])
    if args.expect_file:
        with open(args.expect_file) as f: expected = json.load(f)
    else:
        expected = json.loads(subprocess.run(['docker', 'exec', args.computer, 'cat', INSTALLED], check=True,
                                             capture_output=True, text=True, timeout=60).stdout)
    lines = subprocess.run(['docker', 'exec', args.computer, 'sh', '-c',
                            f"grep -a -E 'CABOOSE_GPU_SESSION_FEATURES|CABOOSE_GPU_HELLO features=' '{args.log}' | tail -n 2000"],
                           capture_output=True, text=True, timeout=120).stdout.splitlines()
    problems, summary = findings(lines, expected)
    if problems is None:
        print(f'CABOOSE_GPU_FEATURES_UNCHECKED {summary}', file=sys.stderr)
        return 2
    if problems:
        print('=' * 72, file=sys.stderr)
        print('CABOOSE_GPU_FEATURES_MISMATCH: the phone session runs without features the release expects', file=sys.stderr)
        for problem in problems: print(f'CABOOSE_GPU_FEATURES_MISMATCH {problem}', file=sys.stderr)
        print(f'CABOOSE_GPU_FEATURES_MISMATCH {summary}', file=sys.stderr)
        print('=' * 72, file=sys.stderr)
        return 1
    print(f'CABOOSE_GPU_FEATURES_OK {summary}')
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv))
