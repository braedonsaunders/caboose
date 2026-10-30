#!/usr/bin/env python3
"""Run the already-built coherent litmus under a bounded private process."""
import argparse
import json
import os
from pathlib import Path
import secrets
import signal
import subprocess
import tempfile


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('binary', type=Path)
    p.add_argument('--timeout', type=float, default=20)
    p.add_argument('--icd', type=Path, help='private Vulkan ICD manifest')
    args = p.parse_args()
    if not 0 < args.timeout <= 120:
        p.error('timeout must be in (0, 120]')
    binary = args.binary.resolve(strict=True)
    env = os.environ.copy()
    if args.icd:
        env['VK_DRIVER_FILES'] = str(args.icd.resolve(strict=True))
        env.pop('VK_ADD_DRIVER_FILES', None)
        env['VK_ICD_FILENAMES'] = env['VK_DRIVER_FILES']
    seed = secrets.randbits(32)
    with tempfile.TemporaryFile() as out, tempfile.TemporaryFile() as err:
        proc = subprocess.Popen([str(binary), str(seed)], stdin=subprocess.DEVNULL,
                                stdout=out, stderr=err, env=env, start_new_session=True)
        try:
            status = proc.wait(timeout=args.timeout)
        except subprocess.TimeoutExpired:
            os.killpg(proc.pid, signal.SIGKILL)
            proc.wait()
            print(json.dumps({'status': 'FAIL', 'reason': 'timeout', 'seed': seed}))
            return 1
        finally:
            try:
                os.killpg(proc.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
        out.seek(0); err.seek(0)
        stdout, stderr = out.read(65537), err.read(65537)
    if len(stdout) > 65536 or len(stderr) > 65536:
        print(json.dumps({'status': 'FAIL', 'reason': 'output limit', 'seed': seed}))
        return 1
    try:
        result = json.loads(stdout.decode())
    except (ValueError, UnicodeDecodeError):
        result = {'status': 'FAIL', 'reason': 'invalid result'}
    if status == 77 and result.get('status') == 'UNSUPPORTED':
        print(json.dumps(result)); return 77
    if status != 0 or result.get('status') != 'PASS' or result.get('seed') != seed:
        print(json.dumps({'status': 'FAIL', 'exit': status, 'seed': seed,
                          'detail': stderr.decode(errors='replace'), 'result': result}))
        return 1
    print(json.dumps(result)); return 0


if __name__ == '__main__':
    raise SystemExit(main())
